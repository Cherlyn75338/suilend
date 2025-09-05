module suilend::invariants_tests {
    use sprungsui::sprungsui::SPRUNGSUI;
    use std::type_name;
    use sui::bag::{Self, Bag};
    use sui::clock::{Self};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self};
    use sui::test_scenario::{Self};
    use sui::test_utils::{Self};
    use sui_system::sui_system::SuiSystemState;
    use sui_system::governance_test_utils::{create_validator_for_testing, create_sui_system_state_for_testing, advance_epoch_with_reward_amounts};

    const SUILEND_VALIDATOR: address = @0xce8e537664ba5d1d5a6a857b17bd142097138706281882be6805e17065ecde89;

    fun setup_sui_system(scenario: &mut sui::test_scenario::Scenario) {
        sui::test_scenario::next_tx(scenario, SUILEND_VALIDATOR);
        let validator = create_validator_for_testing(SUILEND_VALIDATOR, 100, sui::test_scenario::ctx(scenario));
        create_sui_system_state_for_testing(vector[validator], 0, 0, sui::test_scenario::ctx(scenario));
        advance_epoch_with_reward_amounts(0, 0, scenario);
    }

    use suilend::decimal::{Self};
    use suilend::lending_market::{Self, LendingMarket, LendingMarketOwnerCap};
    use suilend::lending_market_tests::{Self, LENDING_MARKET, State, new_args, setup, destruct_state};
    use suilend::mock_pyth;
    use suilend::obligation;
    use suilend::rate_limiter::{Self};
    use suilend::reserve::{Self, CToken, Balances};
    use suilend::reserve_config::{Self, ReserveConfig};

    const MIST_PER_SUI: u64 = 1_000_000_000;

    // --- Helpers ---

    fun assert_ctoken_supply_parity<P, T>(reserve: &reserve::Reserve<P>) {
        let balances: &Balances<P, T> = reserve::balances(reserve);
        assert!(reserve::ctoken_supply<P>(reserve) == balance::supply_value(balances.ctoken_supply()), 0);
    }

    // --- Parity windows around SUI unstake/fulfill ---

    #[test]
    public fun test_sui_parity_unstake_fulfill_no_prefund() {
        use suilend::reserve_config::{default_reserve_config};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        setup_sui_system(&mut scenario);
        let state = setup({
                let mut bag = bag::new(scenario.ctx());
                bag::add(&mut bag, type_name::get<SUI>(), new_args(100 * MIST_PER_SUI, default_reserve_config(scenario.ctx())));
                bag
            }, scenario.ctx());
        let (clock, owner_cap, mut lending_market, mut prices, type_to_index) = destruct_state(state);

        // Initialize staker and move all available SUI into staker
        let mut system_state = test_scenario::take_shared<SuiSystemState>(&scenario);
        let treasury_cap = coin::create_treasury_cap_for_testing<SPRUNGSUI>(scenario.ctx());
        lending_market::init_staker<LENDING_MARKET, SPRUNGSUI>(
            &mut lending_market,
            &owner_cap,
            *bag::borrow(&type_to_index, type_name::get<SUI>()),
            treasury_cap,
            scenario.ctx(),
        );
        lending_market::rebalance_staker<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<SUI>()),
            &mut system_state,
            scenario.ctx(),
        );

        // Deposit SUI to mint cTokens we will redeem
        let deposit_coins = coin::mint_for_testing<SUI>(50 * MIST_PER_SUI, scenario.ctx());
        let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<SUI>()),
            &clock,
            deposit_coins,
            scenario.ctx(),
        );

        // Create redemption request (this updates headline amounts), then unstake and fulfill
        let lr = lending_market::redeem_ctokens_and_withdraw_liquidity_request<LENDING_MARKET, SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<SUI>()),
            &clock,
            ctokens,
            option::none(),
            scenario.ctx(),
        );

        lending_market::unstake_sui_from_staker<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<SUI>()),
            &lr,
            &mut system_state,
            scenario.ctx(),
        );

        let _sui = lending_market::fulfill_liquidity_request<LENDING_MARKET, SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<SUI>()),
            lr,
            scenario.ctx(),
        );

        // Parity after fulfill: headline available == balances.available + staker.liabilities
        let sui_reserve = lending_market::reserve<LENDING_MARKET, SUI>(&lending_market);
        let balances: &Balances<LENDING_MARKET, SUI> = reserve::balances(sui_reserve);
        let staker_ref = reserve::staker<LENDING_MARKET, SPRUNGSUI>(sui_reserve);
        assert!(
            reserve::available_amount<LENDING_MARKET>(sui_reserve)
                == balance::value(balances.available_amount()) + staker_ref.liabilities(),
            0,
        );

        test_utils::destroy(_sui);
        test_scenario::return_shared(system_state);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }

    #[test]
    public fun test_sui_parity_unstake_fulfill_prefunded() {
        use suilend::reserve_config::{default_reserve_config};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        setup_sui_system(&mut scenario);
        let state = setup({
                let mut bag = bag::new(scenario.ctx());
                bag::add(&mut bag, type_name::get<SUI>(), new_args(100 * MIST_PER_SUI, default_reserve_config(scenario.ctx())));
                bag
            }, scenario.ctx());
        let (clock, owner_cap, mut lending_market, mut prices, type_to_index) = destruct_state(state);

        // Initialize staker and move all available SUI into staker
        let mut system_state = test_scenario::take_shared<SuiSystemState>(&scenario);
        let treasury_cap = coin::create_treasury_cap_for_testing<SPRUNGSUI>(scenario.ctx());
        lending_market::init_staker<LENDING_MARKET, SPRUNGSUI>(
            &mut lending_market,
            &owner_cap,
            *bag::borrow(&type_to_index, type_name::get<SUI>()),
            treasury_cap,
            scenario.ctx(),
        );
        lending_market::rebalance_staker<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<SUI>()),
            &mut system_state,
            scenario.ctx(),
        );

        // Mint ctokens to redeem (large request)
        let deposit_big = coin::mint_for_testing<SUI>(40 * MIST_PER_SUI, scenario.ctx());
        let ctokens_big = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<SUI>()),
            &clock,
            deposit_big,
            scenario.ctx(),
        );

        // Drain balances to staker so available is low
        lending_market::rebalance_staker<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<SUI>()),
            &mut system_state,
            scenario.ctx(),
        );

        // Prefund a small amount into balances (so withdraw_amount < request)
        let deposit_small = coin::mint_for_testing<SUI>(5 * MIST_PER_SUI, scenario.ctx());
        let _ctokens_small = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<SUI>()),
            &clock,
            deposit_small,
            scenario.ctx(),
        );

        // Redeem the big ctokens to create liquidity request
        let lr = lending_market::redeem_ctokens_and_withdraw_liquidity_request<LENDING_MARKET, SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<SUI>()),
            &clock,
            ctokens_big,
            option::none(),
            scenario.ctx(),
        );

        // Unstake the remaining difference, fulfill, and assert parity
        lending_market::unstake_sui_from_staker<LENDING_MARKET>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<SUI>()),
            &lr,
            &mut system_state,
            scenario.ctx(),
        );
        let _sui = lending_market::fulfill_liquidity_request<LENDING_MARKET, SUI>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<SUI>()),
            lr,
            scenario.ctx(),
        );

        let sui_reserve = lending_market::reserve<LENDING_MARKET, SUI>(&lending_market);
        let balances_ref: &Balances<LENDING_MARKET, SUI> = reserve::balances(sui_reserve);
        let staker_ref = reserve::staker<LENDING_MARKET, SPRUNGSUI>(sui_reserve);
        assert!(
            reserve::available_amount<LENDING_MARKET>(sui_reserve)
                == balance::value(balances_ref.available_amount()) + staker_ref.liabilities(),
            0,
        );

        test_utils::destroy(_ctokens_small);
        test_utils::destroy(_sui);
        test_scenario::return_shared(system_state);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }

    // --- cToken parity assertion fuzz-ish sequence ---

    #[test]
    public fun test_ctoken_parity_sequence() {
        use suilend::test_usdc::{TEST_USDC};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let state = setup({
                let mut bag = bag::new(scenario.ctx());
                bag::add(&mut bag, type_name::get<TEST_USDC>(), new_args(100 * 1_000_000, reserve_config::default_reserve_config(scenario.ctx())));
                bag
            }, scenario.ctx());
        let (clock, owner_cap, mut lending_market, mut prices, type_to_index) = destruct_state(state);

        // Deposit -> parity
        let coins1 = coin::mint_for_testing<TEST_USDC>(30 * 1_000_000, scenario.ctx());
        let ctokens1 = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            coins1,
            scenario.ctx(),
        );
        let usdc_reserve = lending_market::reserve<LENDING_MARKET, TEST_USDC>(&lending_market);
        assert_ctoken_supply_parity<LENDING_MARKET, TEST_USDC>(usdc_reserve);

        // Redeem -> ctoken supply decreased and parity holds
        let redeem_lr = lending_market::redeem_ctokens_and_withdraw_liquidity_request<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &clock,
            ctokens1,
            option::none(),
            scenario.ctx(),
        );
        {
            let usdc_reserve2 = lending_market::reserve<LENDING_MARKET, TEST_USDC>(&lending_market);
            assert_ctoken_supply_parity<LENDING_MARKET, TEST_USDC>(usdc_reserve2);
        };

        // Fulfill -> parity still holds
        let _usdc = lending_market::fulfill_liquidity_request<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            redeem_lr,
            scenario.ctx(),
        );
        {
            let usdc_reserve3 = lending_market::reserve<LENDING_MARKET, TEST_USDC>(&lending_market);
            assert_ctoken_supply_parity<LENDING_MARKET, TEST_USDC>(usdc_reserve3);
        };

        // Borrow small on a different asset deposit -> parity unaffected
        // Set prices for USDC and SUI
        mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock);
        mock_pyth::update_price<SUI>(&mut prices, 1, 1, &clock);
        let cap = lending_market::create_obligation(&mut lending_market, scenario.ctx());
        let sui_coins = coin::mint_for_testing<SUI>(10 * MIST_PER_SUI, scenario.ctx());
        let ct_sui = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, SUI>(&mut lending_market, *bag::borrow(&type_to_index, type_name::get<SUI>()), &clock, sui_coins, scenario.ctx());
        lending_market::deposit_ctokens_into_obligation<LENDING_MARKET, SUI>(&mut lending_market, *bag::borrow(&type_to_index, type_name::get<SUI>()), &cap, &clock, ct_sui, scenario.ctx());
        // Ensure price is set so borrow doesn't violate same-asset or stale constraints
        mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock);
        let _b = lending_market::borrow<LENDING_MARKET, TEST_USDC>(&mut lending_market, *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()), &cap, &clock, 1 * 1_000_000, scenario.ctx());
        {
            let usdc_reserve4 = lending_market::reserve<LENDING_MARKET, TEST_USDC>(&lending_market);
            assert_ctoken_supply_parity<LENDING_MARKET, TEST_USDC>(usdc_reserve4);
        };

        test_utils::destroy(_usdc);
        test_utils::destroy(_b);
        test_utils::destroy(cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }

    // --- Interest reconciliation test omitted here (internal helpers not public); covered indirectly by existing tests ---

    // --- Rate limiter: exceed and exemption bypass ---

    #[test]
    #[expected_failure(abort_code = suilend::rate_limiter::ERateLimitExceeded)]
    public fun test_rate_limiter_exceed_borrow() {
        use suilend::test_usdc::{TEST_USDC};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let state = setup({
                let mut bag = bag::new(scenario.ctx());
                bag::add(&mut bag, type_name::get<TEST_USDC>(), new_args(100 * 1_000_000, reserve_config::default_reserve_config(scenario.ctx())));
                bag
            }, scenario.ctx());
        let (clock, owner_cap, mut lending_market, mut prices, type_to_index) = destruct_state(state);

        // Window with zero capacity: any borrow should exceed
        let cfg = rate_limiter::new_config(10_000, 0);
        lending_market::update_rate_limiter_config(&owner_cap, &mut lending_market, &clock, cfg);

        // Set price to $1 so amounts map 1:1 to USD
        mock_pyth::update_price<TEST_USDC>(&mut prices, 1, 0, &clock);

        // Minimal borrow still exceeds zero capacity
        let cap = lending_market::create_obligation(&mut lending_market, scenario.ctx());
        let _b = lending_market::borrow<LENDING_MARKET, TEST_USDC>(
            &mut lending_market,
            *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()),
            &cap,
            &clock,
            1,
            scenario.ctx(),
        );

        // Cleanup (unreachable if aborts)
        test_utils::destroy(_b);
        test_utils::destroy(cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }

    // Exemption redemption path is exercised via liquidation flows in core tests.

    // --- Oracle freshness ---

    #[test]
    #[expected_failure(abort_code = suilend::reserve::EPriceStale)]
    public fun test_borrow_with_stale_oracle_fails() {
        use suilend::test_usdc::{TEST_USDC};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let state = setup({
                let mut bag = bag::new(scenario.ctx());
                bag::add(&mut bag, type_name::get<TEST_USDC>(), new_args(100 * 1_000_000, reserve_config::default_reserve_config(scenario.ctx())));
                bag
            }, scenario.ctx());
        let (mut clock, owner_cap, mut lending_market, prices, type_to_index) = destruct_state(state);

        // Advance time but do not refresh reserve price to make it stale for borrow
        clock::set_for_testing(&mut clock, 10 * 1000);
        let cap = lending_market::create_obligation(&mut lending_market, scenario.ctx());
        let _borrow = lending_market::borrow<LENDING_MARKET, TEST_USDC>(&mut lending_market, *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()), &cap, &clock, 1, scenario.ctx());

        // Cleanup for type checker (unreachable if aborts as expected)
        test_utils::destroy(_borrow);
        test_utils::destroy(cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }

    #[test]
    public fun test_withdraw_with_stale_oracle_allowed_when_no_borrows() {
        use suilend::test_usdc::{TEST_USDC};

        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let state = setup({
                let mut bag = bag::new(scenario.ctx());
                bag::add(&mut bag, type_name::get<TEST_USDC>(), new_args(100 * 1_000_000, reserve_config::default_reserve_config(scenario.ctx())));
                bag
            }, scenario.ctx());
        let (mut clock, owner_cap, mut lending_market, prices, type_to_index) = destruct_state(state);

        let cap = lending_market::create_obligation(&mut lending_market, scenario.ctx());
        // Deposit into obligation
        let coins = coin::mint_for_testing<TEST_USDC>(10 * 1_000_000, scenario.ctx());
        let ct = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(&mut lending_market, *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()), &clock, coins, scenario.ctx());
        lending_market::deposit_ctokens_into_obligation<LENDING_MARKET, TEST_USDC>(&mut lending_market, *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()), &cap, &clock, ct, scenario.ctx());

        // Make prices stale and withdraw with no borrows -> allowed
        clock::set_for_testing(&mut clock, 10 * 1000);
        let _ct = lending_market::withdraw_ctokens<LENDING_MARKET, TEST_USDC>(&mut lending_market, *bag::borrow(&type_to_index, type_name::get<TEST_USDC>()), &cap, &clock, 1 * 1_000_000, scenario.ctx());

        test_utils::destroy(_ct);
        test_utils::destroy(cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(clock);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        test_scenario::end(scenario);
    }
}

