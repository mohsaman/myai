pub mod s1ap;

use anyhow::Result;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum S1ApError {
    #[error("gRPC error: {0}")]
    Grpc(String),
    #[error("Unsupported message")]
    Unsupported,
}

pub fn serve_s1ap() -> Result<()> {
    // TODO: start tonic server with generated proto services
    Ok(())
}
