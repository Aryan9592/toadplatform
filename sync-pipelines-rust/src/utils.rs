use sqlx::types::chrono::NaiveTime;

pub fn get_last_synced_time(_table: String) -> NaiveTime {
    // gets last seen time for the table
    unimplemented!();
}

pub fn update_last_synced_time(_table: String, _last_sync_time: NaiveTime) {
    // update the last sync time for the table
    unimplemented!();
}

pub fn generate_txn_id() -> String {
    // generate and return random id
    unimplemented!();
}
