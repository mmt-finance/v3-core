module mmt_v3::ve;

use mmt_v3::admin;
use mmt_v3::app::VeCap;
use mmt_v3::pool::{Self, Pool};
use mmt_v3::version::{Self, Version};
use sui::balance::Balance;
use sui::clock::Clock;

public fun set_pool_ve_enabled_state<X, Y>(pool: &mut Pool<X, Y>, is_enabled: bool, version: &Version, _: &VeCap) {
    version::assert_supported_version(version);
    pool::assert_not_pause(pool);

    pool::set_ve_enabled_state(pool, is_enabled);
}

public fun initialize_pool_reward_with_cap<X, Y, R>(
    pool: &mut Pool<X, Y>,
    _: &VeCap,
    start_time: u64,
    additional_seconds: u64,
    initial_balance: Balance<R>,
    clock: &Clock,
    version: &Version,
    ctx: &TxContext,
): (u64, u64) {
    version::assert_supported_version(version);
    pool::assert_not_pause(pool);

    admin::initialize_pool_reward_<X, Y, R>(
        pool,
        start_time,
        additional_seconds,
        initial_balance,
        clock,
        ctx,
    )
}

public fun update_pool_reward_emission_with_cap<X, Y, R>(
    pool: &mut Pool<X, Y>,
    _: &VeCap,
    additional_balance: Balance<R>,
    additional_seconds: u64,
    clock: &Clock,
    version: &Version,
    ctx: &TxContext,
): (u64, u64) {
    version::assert_supported_version(version);
    pool::assert_not_pause(pool);

    admin::update_pool_reward_emission_(pool, additional_balance, additional_seconds, clock, ctx)
}

public fun collect_protocol_fee_with_cap<X, Y>(
    pool: &mut Pool<X, Y>,
    _: &VeCap,
    amount_x: u64,
    amount_y: u64,
    version: &Version,
    ctx: &TxContext,
): (Balance<X>, Balance<Y>) {
    version::assert_supported_version(version);
    pool::assert_not_pause(pool);

    admin::collect_protocol_fees_(pool, amount_x, amount_y, ctx)
}
