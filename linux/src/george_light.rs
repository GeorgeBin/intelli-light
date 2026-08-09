use crate::config::{validate_http_address, GeorgeLightConfig};
use crate::LightState;
use serde_json::json;
use std::io::{self, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

pub const LEASE_REFRESH_SECONDS: f64 = 240.0;
pub const RETRY_DELAYS_SECONDS: [f64; 5] = [2.0, 5.0, 10.0, 30.0, 60.0];

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HttpRequest {
    pub host: String,
    pub port: u16,
    pub path: String,
    pub body: Option<Vec<u8>>,
}

#[derive(Clone, Debug)]
pub struct PendingRequest {
    pub request: HttpRequest,
    generation: u64,
    state: LightState,
    disable_clear: bool,
}

pub trait HttpTransport {
    fn send(&mut self, request: &HttpRequest) -> io::Result<u16>;
}

#[derive(Default)]
pub struct TcpHttpTransport;

impl HttpTransport for TcpHttpTransport {
    fn send(&mut self, request: &HttpRequest) -> io::Result<u16> {
        let address = (request.host.as_str(), request.port)
            .to_socket_addrs()?
            .next()
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::AddrNotAvailable, "host did not resolve")
            })?;
        let timeout = Duration::from_secs(3);
        let mut stream = TcpStream::connect_timeout(&address, timeout)?;
        stream.set_read_timeout(Some(timeout))?;
        stream.set_write_timeout(Some(timeout))?;
        let body = request.body.as_deref().unwrap_or_default();
        let content_headers = if request.body.is_some() {
            format!(
                "Content-Type: application/json\r\nContent-Length: {}\r\n",
                body.len()
            )
        } else {
            "Content-Length: 0\r\n".to_owned()
        };
        write!(
            stream,
            "POST {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n{}\r\n",
            request.path, request.host, content_headers
        )?;
        stream.write_all(body)?;
        stream.flush()?;
        let mut response = Vec::with_capacity(1024);
        let mut buffer = [0_u8; 256];
        while response.len() < 4096 && !response.windows(4).any(|bytes| bytes == b"\r\n\r\n") {
            let count = stream.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            response.extend_from_slice(&buffer[..count]);
        }
        let response = String::from_utf8_lossy(&response);
        let status = response
            .lines()
            .next()
            .and_then(|line| line.split_whitespace().nth(1))
            .and_then(|value| value.parse().ok())
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid HTTP response"))?;
        Ok(status)
    }
}

pub struct GeorgeLightOutput {
    config: GeorgeLightConfig,
    desired_state: Option<LightState>,
    desired_generation: u64,
    in_flight: bool,
    retry_attempt: usize,
    next_due: Option<f64>,
    pending_disable_clear: bool,
}

impl GeorgeLightOutput {
    pub fn new(config: GeorgeLightConfig) -> Result<Self, String> {
        validate_http_address(&config.address)?;
        Ok(Self {
            config,
            desired_state: None,
            desired_generation: 0,
            in_flight: false,
            retry_attempt: 0,
            next_due: None,
            pending_disable_clear: false,
        })
    }

    pub fn set_state(&mut self, state: LightState, now: f64) {
        if self.desired_state == Some(state) {
            return;
        }
        self.desired_state = Some(state);
        self.desired_generation = self.desired_generation.wrapping_add(1);
        self.retry_attempt = 0;
        self.next_due = Some(now);
    }

    pub fn set_enabled(&mut self, enabled: bool, now: f64) {
        if self.config.enabled == enabled {
            return;
        }
        self.config.enabled = enabled;
        self.desired_generation = self.desired_generation.wrapping_add(1);
        self.retry_attempt = 0;
        self.next_due = Some(now);
        self.pending_disable_clear = !enabled;
    }

    pub fn next_request(&mut self, now: f64) -> Result<Option<PendingRequest>, String> {
        if self.in_flight || self.next_due.is_some_and(|due| due > now) {
            return Ok(None);
        }
        let (state, disable_clear) = if self.pending_disable_clear {
            self.pending_disable_clear = false;
            (LightState::Idle, true)
        } else {
            let Some(state) = self.desired_state else {
                return Ok(None);
            };
            if !self.config.enabled {
                return Ok(None);
            }
            (state, false)
        };
        self.next_due = None;
        self.in_flight = true;
        Ok(Some(PendingRequest {
            request: self.make_request(state)?,
            generation: self.desired_generation,
            state,
            disable_clear,
        }))
    }

    pub fn complete(&mut self, pending: &PendingRequest, succeeded: bool, now: f64) {
        self.in_flight = false;
        if pending.disable_clear {
            return;
        }
        if !self.config.enabled
            || pending.generation != self.desired_generation
            || self.desired_state != Some(pending.state)
        {
            if self.config.enabled && self.desired_state.is_some() {
                self.next_due = Some(now);
            }
            return;
        }
        if succeeded {
            self.retry_attempt = 0;
            self.next_due = matches!(
                pending.state,
                LightState::Working | LightState::ActionRequired
            )
            .then_some(now + LEASE_REFRESH_SECONDS);
        } else {
            let index = self.retry_attempt.min(RETRY_DELAYS_SECONDS.len() - 1);
            self.next_due = Some(now + RETRY_DELAYS_SECONDS[index]);
            self.retry_attempt = (self.retry_attempt + 1).min(RETRY_DELAYS_SECONDS.len());
        }
    }

    pub fn drive<T: HttpTransport>(&mut self, now: f64, transport: &mut T) -> Result<bool, String> {
        let Some(pending) = self.next_request(now)? else {
            return Ok(false);
        };
        let result = transport.send(&pending.request);
        let succeeded = result
            .as_ref()
            .is_ok_and(|status| (200..300).contains(status));
        self.complete(&pending, succeeded, now);
        result.map_err(|error| error.to_string())?;
        Ok(succeeded)
    }

    pub fn clear_request(&self) -> Result<HttpRequest, String> {
        self.make_request(LightState::Idle)
    }

    fn make_request(&self, state: LightState) -> Result<HttpRequest, String> {
        let (host, port) = parse_address(&self.config.address)?;
        let (path, body) = if state == LightState::Idle {
            ("/api/v1/codex/clear".to_owned(), None)
        } else {
            let effect = self
                .config
                .effects
                .for_state(state)
                .ok_or("missing effect")?;
            let body = serde_json::to_vec(&json!({
                "color": effect.color,
                "mode_id": effect.mode_id,
                "duration_sec": effect.duration_sec,
                "brightness": effect.brightness,
            }))
            .map_err(|error| error.to_string())?;
            ("/api/v1/codex/display".to_owned(), Some(body))
        };
        Ok(HttpRequest {
            host,
            port,
            path,
            body,
        })
    }
}

fn parse_address(address: &str) -> Result<(String, u16), String> {
    validate_http_address(address)?;
    let authority = address.trim_start_matches("http://");
    match authority.rsplit_once(':') {
        Some((host, port)) if !host.is_empty() => Ok((
            host.to_owned(),
            port.parse().map_err(|_| "invalid HTTP port".to_owned())?,
        )),
        _ => Ok((authority.to_owned(), 80)),
    }
}
