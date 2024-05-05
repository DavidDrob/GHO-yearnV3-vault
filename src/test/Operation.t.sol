// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ICurveGauge.sol";
import "../interfaces/ICurvePool.sol";

contract OperationTest is Test, Setup {
    ICurveGauge gauge;
    ICurvePool pool;

    function setUp() public virtual override {
        super.setUp();
        gauge = ICurveGauge(address(tokenAddrs["gauge-deposit"]));
        pool = ICurvePool(tokenAddrs["gho-crvUSD-pool"]);
    }

    function test_setupStrategyOK() public {
        console.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        // TODO: add additional check on strat params
    }

    function test_deposit_into_crv() public {
        uint256 _amount = 200e18;
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertGt(strategy.balanceOf(user), 0);
        assertGt(gauge.balanceOf(address(strategy)), 0);
    }

    function test_withdraw_partially() public {
        uint256 _amount = 200e18;

        mintAndDepositIntoStrategy(strategy, user, _amount);
        uint256 shares = strategy.balanceOf(user);
        assertGt(shares, 0);

        skip(5 days);

        uint256 maxLoss = 10_000; // 100%
        uint256 toWithdraw = (shares * 2_000) / 10_000;

        vm.startPrank(user);
        strategy.withdraw(toWithdraw, user, user, maxLoss);
        vm.stopPrank();

        assertApproxEqRel(strategy.balanceOf(user), (shares * 8_000) / 10_000, 0.05e18);
    }

    // TODO: fuzz maxLoss
    function test_withdraw_all() public {
        uint256 _amount = 200e18;

        vm.prank(user);
        mintAndDepositIntoStrategy(strategy, user, _amount);
        uint256 shares = strategy.balanceOf(user);
        assertGt(shares, 0);

        skip(10 days);

        uint256 maxLoss = 10_000; // 100%
        vm.prank(user);
        strategy.withdraw(shares, user, user, maxLoss);

        assertEq(strategy.balanceOf(user), 0);
        assertApproxEqRel(asset.balanceOf(user), _amount, 0.05e18);
    }

    function test_redeem_all() public {
        uint256 _amount = 200e18;

        vm.prank(user);
        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertGt(strategy.balanceOf(user), 0);

        skip(1 days);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertEq(strategy.balanceOf(user), 0);
        assertApproxEqRel(asset.balanceOf(user), _amount, 0.05e18);
    }

    function test_claim_crv() public {
        uint256 _amount = 20_000e18;

        mintAndDepositIntoStrategy(strategy, user, _amount);

        skip(5 days);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertGt(profit, loss);
    }

    function test_is_profitable() public {
        uint256 _amount = 200_000e18;

        vm.prank(user);
        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertGt(strategy.balanceOf(user), 0);

        skip(30 days);
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertGt(profit, loss);

        vm.startPrank(user);
        strategy.redeem(strategy.balanceOf(user), user, user);
        vm.stopPrank();

        assertGt(asset.balanceOf(user), _amount);
    }

    function test_operation(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // TODO: Implement logic so totalDebt is _amount and totalIdle = 0.
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");
        assertEq(strategy.totalDebt(), 0, "!totalDebt");
        assertEq(strategy.totalIdle(), _amount, "!totalIdle");

        // Earn Interest
        skip(1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // TODO: Implement logic so totalDebt is _amount and totalIdle = 0.
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");
        assertEq(strategy.totalDebt(), 0, "!totalDebt");
        assertEq(strategy.totalIdle(), _amount, "!totalIdle");

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );
    }

    function test_profitableReport_withFees(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS));

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // TODO: Implement logic so totalDebt is _amount and totalIdle = 0.
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");
        assertEq(strategy.totalDebt(), 0, "!totalDebt");
        assertEq(strategy.totalIdle(), _amount, "!totalIdle");

        // Earn Interest
        skip(1 days);

        // TODO: implement logic to simulate earning interest.
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(
            asset.balanceOf(user),
            balanceBefore + _amount,
            "!final balance"
        );

        vm.prank(performanceFeeRecipient);
        strategy.redeem(
            expectedShares,
            performanceFeeRecipient,
            performanceFeeRecipient
        );

        checkStrategyTotals(strategy, 0, 0, 0);

        assertGe(
            asset.balanceOf(performanceFeeRecipient),
            expectedShares,
            "!perf fee out"
        );
    }

    function test_tendTrigger(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        (bool trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Skip some time
        skip(1 days);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(keeper);
        strategy.report();

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Unlock Profits
        skip(strategy.profitMaxUnlockTime());

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.prank(user);
        strategy.redeem(_amount, user, user);

        (trigger, ) = strategy.tendTrigger();
        assertTrue(!trigger);
    }
}
