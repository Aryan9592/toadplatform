use crate::errors::ApiError;
use crate::models::metadata::Metadata;
use crate::CONFIG;

#[derive(Clone)]
pub struct MetadataService {}

impl MetadataService {
    pub fn get_chain(&self) -> Result<Metadata, ApiError> {
        Ok(Metadata {
            chain: CONFIG.current_chain.clone(),
            currency: CONFIG.chains[&CONFIG.current_chain].currency.clone(),
        })
    }
}
