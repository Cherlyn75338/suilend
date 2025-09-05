module suilend::invariant_tests {
    use std::type_name;
    use sui::bag::{Self, Bag};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::test_scenario::{Self};
    use sui::test_utils::{Self};

    use suilend::decimal::{Self, Decimal, add, sub, le, ge};
    use suilend::lending_market::{Self, LendingMarket, LendingMarketOwnerCap, ObligationOwnerCap};
    use suilend::lending_market_tests::{Self, LENDING_MARKET, State as LMState};
    use suilend::mock_pyth::{Self as MockPyth};
    use suilend::obligation::{Self as Obligation};
    use suilend::reserve::{Self as Reserve, CToken};

    use suilend::test_usdc::{Self, TEST_USDC};
    use suilend::test_sui::{Self, TEST_SUI};

    const MINT_USDC: u64 = 5_000_000_000; // 5,000 USDC (6dp)
    const MINT_SUI: u64 = 5_000_000_000;  // 5 SUI (9dp)

    fun setup_market(ctx: &mut TxContext): LMState {
        let reserve_args = bag::new(ctx);
        lending_market_tests::setup(reserve_args, ctx)
    }

    fun update_prices(state: &mut LMState) {
        // Set both prices fresh and reasonable
        // Use integer prices with expo=0 for simplicity
        MockPyth::update_price<TEST_USDC>(&mut state.prices, 1_000_000, 6, &state.clock); // $1.0
        MockPyth::update_price<TEST_SUI>(&mut state.prices, 10_000_000_000, 9, &state.clock); // $10.0
    }

    fun deposit_initial_liquidity(
        state: &mut LMState,
        ctx: &mut TxContext,
    ) {
        let usdc = coin::mint_for_testing<TEST_USDC>(MINT_USDC, ctx);
        let sui = coin::mint_for_testing<TEST_SUI>(MINT_SUI, ctx);

        let _ctokens_usdc = lending_market::deposit_liquidity_and_mint_ctokens<
            LENDING_MARKET,
            TEST_USDC,
        >(&mut state.lending_market, 0, &state.clock, usdc, ctx);

        let _ctokens_sui = lending_market::deposit_liquidity_and_mint_ctokens<
            LENDING_MARKET,
            TEST_SUI,
        >(&mut state.lending_market, 1, &state.clock, sui, ctx);
    }

    fun create_and_fund_obligation(
        state: &mut LMState,
        ctx: &mut TxContext,
        deposit_ctoken_usdc: u64,
        deposit_ctoken_sui: u64,
    ): ObligationOwnerCap<LENDING_MARKET> {
        let cap = lending_market::create_obligation<LENDING_MARKET>(&mut state.lending_market, ctx);

        // Mint cTokens to deposit by depositing and withdrawing from market into the obligation
        // Simpler: deposit liquidity, get cTokens, then deposit cTokens into obligation
        if (deposit_ctoken_usdc > 0) {
            let coins = coin::mint_for_testing<TEST_USDC>(deposit_ctoken_usdc, ctx);
            let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<
                LENDING_MARKET,
                TEST_USDC,
            >(&mut state.lending_market, 0, &state.clock, coins, ctx);
            lending_market::deposit_ctokens_into_obligation<
                LENDING_MARKET,
                TEST_USDC,
            >(&mut state.lending_market, 0, &cap, &state.clock, ctokens, ctx);
        };

        if (deposit_ctoken_sui > 0) {
            let coins = coin::mint_for_testing<TEST_SUI>(deposit_ctoken_sui, ctx);
            let ctokens = lending_market::deposit_liquidity_and_mint_ctokens<
                LENDING_MARKET,
                TEST_SUI,
            >(&mut state.lending_market, 1, &state.clock, coins, ctx);
            lending_market::deposit_ctokens_into_obligation<
                LENDING_MARKET,
                TEST_SUI,
            >(&mut state.lending_market, 1, &cap, &state.clock, ctokens, ctx);
        };

        cap
    }

    #[test]
    fun invariant_basic_health_and_reserve_properties() {
        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let mut state = setup_market(test_scenario::ctx(&mut scenario));

        update_prices(&mut state);
        deposit_initial_liquidity(&mut state, test_scenario::ctx(&mut scenario));

        // Create an obligation and fund it with deposits in both reserves
        let cap = create_and_fund_obligation(&mut state, test_scenario::ctx(&mut scenario), 1_000_000, 1_000_000_000);

        // Borrow a small amount of USDC
        let _loan_usdc: Coin<TEST_USDC> = lending_market::borrow<
            LENDING_MARKET,
            TEST_USDC
        >(&mut state.lending_market, 0, &cap, &state.clock, 100_000, test_scenario::ctx(&mut scenario));

        // Withdraw a small portion of SUI collateral cTokens
        let _withdrawn_sui_ctokens: Coin<CToken<LENDING_MARKET, TEST_SUI>> = lending_market::withdraw_ctokens<
            LENDING_MARKET,
            TEST_SUI
        >(&mut state.lending_market, 1, &cap, &state.clock, 10_000_000, test_scenario::ctx(&mut scenario));

        // Obligation should remain healthy
        let obligation_ref = lending_market::obligation<LENDING_MARKET>(&state.lending_market, cap.obligation_id);
        assert!(Obligation::is_healthy(obligation_ref), 0);

        // Reserve-level invariants for USDC reserve (index 0)
        let reserve_usdc_ref = lending_market::reserve_ref<LENDING_MARKET, TEST_USDC>(&state.lending_market, 0);
        let ratio_before = Reserve::ctoken_ratio(reserve_usdc_ref);
        assert!(ge(ratio_before, decimal::from(1)), 0);

        let total_supply = Reserve::total_supply(reserve_usdc_ref);
        let expected_total = sub(
            add(
                decimal::from(Reserve::available_amount(reserve_usdc_ref)),
                Reserve::borrowed_amount(reserve_usdc_ref)
            ),
            Reserve::unclaimed_spread_fees(reserve_usdc_ref)
        );
        assert!(total_supply == expected_total, 0);

        // If ctoken supply > 0, available_amount should be 0 or >= 100 (MIN_AVAILABLE_AMOUNT)
        let ctoken_supply_val = Reserve::ctoken_supply(reserve_usdc_ref);
        if (ctoken_supply_val > 0) {
            let avail = Reserve::available_amount(reserve_usdc_ref);
            assert!(avail == 0 || avail >= 100, 0);
        };

        // Compound interest should not decrease ctoken ratio
        lending_market::compound_interest<LENDING_MARKET>(&mut state.lending_market, 0, &state.clock);
        let reserve_usdc_ref_2 = lending_market::reserve_ref<LENDING_MARKET, TEST_USDC>(&state.lending_market, 0);
        let ratio_after = Reserve::ctoken_ratio(reserve_usdc_ref_2);
        assert!(ge(ratio_after, ratio_before), 0);

        // Utilization is always <= 1
        let util = Reserve::calculate_utilization_rate(reserve_usdc_ref_2);
        assert!(le(util, decimal::from(1)), 0);

        test_utils::destroy(cap);
        test_utils::destroy(state.owner_cap);
        test_utils::destroy(state.lending_market);
        test_utils::destroy(state.prices);
        test_utils::destroy(state.type_to_index);
        test_utils::destroy(state.clock);
        test_scenario::end(scenario);
    }

    #[test]
    fun invariant_liquidation_path_succeeds_when_unhealthy() {
        let owner = @0x26;
        let mut scenario = test_scenario::begin(owner);
        let mut state = setup_market(test_scenario::ctx(&mut scenario));

        update_prices(&mut state);
        deposit_initial_liquidity(&mut state, test_scenario::ctx(&mut scenario));

        // Fund obligation with SUI as collateral and borrow USDC against it
        let cap = create_and_fund_obligation(&mut state, test_scenario::ctx(&mut scenario), 0, 2_000_000_000);

        let _loan_usdc: Coin<TEST_USDC> = lending_market::borrow<
            LENDING_MARKET,
            TEST_USDC
        >(&mut state.lending_market, 0, &cap, &state.clock, 500_000, test_scenario::ctx(&mut scenario));

        // Crash SUI price to make the position liquidatable
        // Set SUI to $0.01
        MockPyth::update_decimal_price<TEST_SUI>(&mut state.prices, 1, 2, true, &state.clock);

        // Mint USDC for liquidator
        let mut repay_funds = coin::mint_for_testing<TEST_USDC>(1_000_000_000, test_scenario::ctx(&mut scenario));

        let (_seized_ctokens, _exemption) = lending_market::liquidate<
            LENDING_MARKET,
            TEST_USDC,
            TEST_SUI
        >(
            &mut state.lending_market,
            cap.obligation_id,
            0, // repay USDC reserve
            1, // seize SUI collateral
            &state.clock,
            &mut repay_funds,
            test_scenario::ctx(&mut scenario),
        );

        // After liquidation, obligation may or may not be healthy depending on repay amount, but must not have stale oracles
        let obligation_ref = lending_market::obligation<LENDING_MARKET>(&state.lending_market, cap.obligation_id);
        // Sanity: values are non-negative
        assert!(ge(Obligation::deposited_value_usd(obligation_ref), decimal::from(0)), 0);
        assert!(ge(Obligation::unweighted_borrowed_value_usd(obligation_ref), decimal::from(0)), 0);

        test_utils::destroy(repay_funds);
        test_utils::destroy(cap);
        test_utils::destroy(state.owner_cap);
        test_utils::destroy(state.lending_market);
        test_utils::destroy(state.prices);
        test_utils::destroy(state.type_to_index);
        test_utils::destroy(state.clock);
        test_scenario::end(scenario);
    }
}

