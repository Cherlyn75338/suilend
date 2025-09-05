module suilend::invariant_tests {
    use sui::test_utils::{Self};
    use sui::test_scenario::{Self, Scenario};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui_system::governance_test_utils::{Self, create_validator_for_testing, create_sui_system_state_for_testing, advance_epoch_with_reward_amounts};
    use sui_system::sui_system::SuiSystemState;

    use suilend::decimal::{Self};
    use suilend::lending_market::{Self, LendingMarket, LendingMarketOwnerCap};
    use suilend::reserve::{Self, CToken};
    use suilend::reserve_config;
    use suilend::mock_pyth::{Self as mock_oracle, PriceState};
    use suilend::lending_market_tests::{Self as lm_tests, LENDING_MARKET};
    use suilend::test_sui::TEST_SUI;
    use suilend::test_usdc::TEST_USDC;

    const OWNER: address = @0x26;
    const MIST_PER_SUI: u64 = 1_000_000_000;

    fun setup_market_with_sui_and_usdc(ctx: &mut TxContext): (Clock, LendingMarketOwnerCap<LENDING_MARKET>, LendingMarket<LENDING_MARKET>, PriceState, Bag) {
        let mut reserve_args = bag::new(ctx);
        bag::add(&mut reserve_args, type_name::get<TEST_SUI>(), lm_tests::new_args(1000 * MIST_PER_SUI, reserve_config::default_reserve_config(ctx)));
        bag::add(&mut reserve_args, type_name::get<TEST_USDC>(), lm_tests::new_args(1_000_000_000, reserve_config::default_reserve_config(ctx)));
        let state = lm_tests::setup(reserve_args, ctx);
        lm_tests::destruct_state(state)
    }

    fun setup_sui_system(scenario: &mut Scenario) {
        let validator = create_validator_for_testing(OWNER, 100, test_scenario::ctx(scenario));
        create_sui_system_state_for_testing(vector[validator], 0, 0, test_scenario::ctx(scenario));
        advance_epoch_with_reward_amounts(0, 0, scenario);
    }

    #[test]
    fun balance_and_ctoken_parity_on_deposit_and_redeem() {
        let mut scenario = test_scenario::begin(OWNER);
        let (clock, mut owner_cap, mut lending_market, mut prices, mut type_to_index) = setup_market_with_sui_and_usdc(scenario.ctx());

        // Use USDC for simple parity checks
        let usdc_idx = *bag::borrow(&type_to_index, type_name::get<TEST_USDC>());
        let deposit = coin::create_for_testing<TEST_USDC>(1_000_000);
        let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(&mut lending_market, usdc_idx, &clock, deposit, scenario.ctx());

        let reserve = vector::borrow(lending_market::reserves_mut_for_testing(&mut lending_market), usdc_idx);
        reserve::assert_balance_parity_no_pending<LENDING_MARKET, TEST_USDC>(reserve);
        reserve::assert_ctoken_supply_parity<LENDING_MARKET, TEST_USDC>(reserve);

        let coins = lending_market::redeem_ctokens_and_withdraw_liquidity<LENDING_MARKET, TEST_USDC>(&mut lending_market, usdc_idx, &clock, ctokens, option::none(), scenario.ctx());
        test_utils::destroy(coins);

        let reserve2 = vector::borrow(lending_market::reserves_mut_for_testing(&mut lending_market), usdc_idx);
        reserve::assert_balance_parity_no_pending<LENDING_MARKET, TEST_USDC>(reserve2);
        reserve::assert_ctoken_supply_parity<LENDING_MARKET, TEST_USDC>(reserve2);

        // cleanup
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    #[test]
    fun staker_desync_safety() {
        use sui::bag::{Self, Bag};
        let mut scenario = test_scenario::begin(OWNER);
        setup_sui_system(&mut scenario);
        let (mut owner_cap, mut lending_market, clock, mut prices, mut type_to_index) = {
            let state = lm_tests::setup(bag::new(scenario.ctx()), scenario.ctx());
            let (c, oc, lm, p, t2i) = lm_tests::destruct_state(state);
            (oc, lm, c, p, t2i)
        };

        // Ensure SUI reserve present
        let sui_idx = *bag::borrow(&type_to_index, type_name::get<TEST_SUI>());

        // Deposit SUI and init staker
        let sui_deposit = coin::create_for_testing<SUI>(200 * MIST_PER_SUI);
        let _sui_ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, SUI>(&mut lending_market, sui_idx, &clock, sui_deposit, scenario.ctx());

        let treasury = coin::create_treasury_cap_for_testing<sprungsui::sprungsui::SPRUNGSUI>(scenario.ctx());
        lending_market::init_staker<LENDING_MARKET, sprungsui::sprungsui::SPRUNGSUI>(&mut lending_market, &owner_cap, sui_idx, treasury, scenario.ctx());

        // Rebalance staker to move funds out of Balances into staker
        {
            let mut system_state = test_scenario::take_shared<SuiSystemState>(&scenario);
            lending_market::rebalance_staker<LENDING_MARKET>(&mut lending_market, sui_idx, &mut system_state, scenario.ctx());
            test_scenario::return_shared(system_state);
        }

        // After rebalancing, parity with staker liabilities should hold
        let sui_reserve = vector::borrow(lending_market::reserves_mut_for_testing(&mut lending_market), sui_idx);
        reserve::assert_balance_parity_no_pending<LENDING_MARKET, SUI>(sui_reserve);

        // Attempt to request a withdrawal slightly below headline available_amount; should succeed or revert per MIN_AVAILABLE
        let ctoken_max = coin::create_for_testing<CToken<LENDING_MARKET, SUI>>(1000);
        let _req = lending_market::redeem_ctokens_and_withdraw_liquidity_request<LENDING_MARKET, SUI>(&mut lending_market, sui_idx, &clock, ctoken_max, option::none(), scenario.ctx());

        // cleanup
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = suilend::reserve::EPriceStale)]
    fun oracle_freshness_enforced_on_borrow() {
        let mut scenario = test_scenario::begin(OWNER);
        let (clock, mut owner_cap, mut lending_market, mut prices, mut type_to_index) = setup_market_with_sui_and_usdc(scenario.ctx());

        let usdc_idx = *bag::borrow(&type_to_index, type_name::get<TEST_USDC>());
        let (cap, obligation_id) = {
            let cap = lending_market::create_obligation<LENDING_MARKET>(&mut lending_market, scenario.ctx());
            (cap, lending_market::obligation_id(&cap))
        };

        // Intentionally avoid refreshing price in the same second to trigger staleness
        let _borrow = lending_market::borrow<LENDING_MARKET, TEST_USDC>(&mut lending_market, usdc_idx, &cap, &clock, 1, scenario.ctx());

        // cleanup
        lending_market::destroy_for_testing(cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    #[test]
    fun rate_limiter_tracks_outflows_on_borrow_and_redeem_request() {
        let mut scenario = test_scenario::begin(OWNER);
        let (clock, mut owner_cap, mut lending_market, mut prices, mut type_to_index) = setup_market_with_sui_and_usdc(scenario.ctx());
        // USDC index
        let usdc_idx = *bag::borrow(&type_to_index, type_name::get<TEST_USDC>());

        // deposit some usdc
        let deposit = coin::create_for_testing<TEST_USDC>(1_000_000);
        let _ctokens = lending_market::deposit_liquidity_and_mint_ctokens<LENDING_MARKET, TEST_USDC>(&mut lending_market, usdc_idx, &clock, deposit, scenario.ctx());

        let cap = lending_market::create_obligation<LENDING_MARKET>(&mut lending_market, scenario.ctx());
        lending_market::refresh_reserve_price(&mut lending_market, usdc_idx, &clock, mock_oracle::get_price_obj<TEST_USDC>(&prices));

        // borrow small amount to ensure process_qty path
        let _coins = lending_market::borrow<LENDING_MARKET, TEST_USDC>(&mut lending_market, usdc_idx, &cap, &clock, 100, scenario.ctx());

        // redeem request should process rate limiter as well
        let ctokens_small = coin::create_for_testing<CToken<LENDING_MARKET, TEST_USDC>>(100);
        let _req = lending_market::redeem_ctokens_and_withdraw_liquidity_request<LENDING_MARKET, TEST_USDC>(&mut lending_market, usdc_idx, &clock, ctokens_small, option::none(), scenario.ctx());

        // cleanup
        lending_market::destroy_for_testing(cap);
        test_utils::destroy(owner_cap);
        test_utils::destroy(lending_market);
        test_utils::destroy(prices);
        test_utils::destroy(type_to_index);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
}

