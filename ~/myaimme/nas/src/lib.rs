pub mod nas;

use anyhow::Result;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum NasError {
    #[error("ASN.1 parsing error: {0}")]
    AsnParse(String),
    #[error("Unsupported NAS message type")]
    Unsupported,
}

pub fn parse_nas_message(_data: &[u8]) -> Result<()> {
    // TODO: implement ASN.1 decoding using rasn
    Ok(())
}
