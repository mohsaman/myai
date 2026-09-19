pub mod rrc;

use anyhow::Result;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum RrcError {
    #[error("ASN.1 parsing error: {0}")]
    AsnParse(String),
    #[error("Unsupported RRC message type")]
    Unsupported,
}

pub fn handle_rrc_connect_request(_data: &[u8]) -> Result<()> {
    // TODO: implement ASN.1 decoding using rasn
    Ok(())
}
