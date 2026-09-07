module mmt_v3::current_version;

// Increment this each time the mmt_v3 upgrades.
const CURRENT_MAJOR_VERSION: u64 = 1;
const CURRENT_MINOR_VERSION: u64 = 7;

public fun current_major_version(): u64 {
    CURRENT_MAJOR_VERSION
}

public fun current_minor_version(): u64 {
    CURRENT_MINOR_VERSION
}
