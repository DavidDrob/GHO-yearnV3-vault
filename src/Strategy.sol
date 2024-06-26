// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "forge-std/console.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

import "./interfaces/IGhoToken.sol";
import "./interfaces/ICurvePool.sol";
import "./interfaces/convex/IConvex.sol";
import "./interfaces/convex/IConvexRewards.sol";
import "./interfaces/IDepositZap.sol";
import "./interfaces/IGauge.sol";
import "./interfaces/IMinter.sol";
import "./interfaces/ITriCryptoNG.sol";
import "./interfaces/ICryptoSwap.sol";


// custom errors
error NoCRVMinted();
error ZeroLP();
error NotEnoughCVX();

/**
 * The `TokenizedStrategy` variable can be used to retrieve the strategies
 * specific storage data your contract.
 *
 *       i.e. uint256 totalAssets = TokenizedStrategy.totalAssets()
 *
 * This can not be used for write functions. Any TokenizedStrategy
 * variables that need to be updated post deployment will need to
 * come from an external call from the strategies specific `management`.
 */

// NOTE: To implement permissioned functions you can use the onlyManagement, onlyEmergencyAuthorized and onlyKeepers modifiers

contract Strategy is BaseStrategy {
    using SafeERC20 for ERC20;

    address public constant gho = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f; // index 0
    address public constant crvusd = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E; // index 1
    address public constant crv = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address public constant cvxDeposit =
        0x453CAFf58C6a1E01f7E19Dbf5Fa8382ca8cA3Ec1;
    address public constant weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    ICurvePool public constant pool =
        ICurvePool(0x635EF0056A597D13863B73825CcA297236578595);
    ITriCryptoNG public constant rewardsPool =
        ITriCryptoNG(0x4eBdF703948ddCEA3B11f675B4D1Fba9d2414A14);
    IConvex public constant convex =
        IConvex(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    IConvexRewards public constant convexRewards =
        IConvexRewards(0x5eC758f79b96AE74e7F1Ba9583009aFB3fc8eACB);
    IDepositZap public constant zap =
        IDepositZap(0xA79828DF1850E8a3A3064576f380D90aECDD3359);
    IGauge public constant gauge =
        IGauge(0x4717C25df44e280ec5b31aCBd8C194e1eD24efe2);
    IMinter public constant minter =
        IMinter(0xd061D61a4d941c39E5453435B6345Dc261C2fcE0);
    IERC20 public constant convexToken =
        IERC20(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    ICryptoSwap public constant cvxEthPool =
        ICryptoSwap(0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4);

    uint256 public constant PID = 335;

    constructor(
        address _asset,
        string memory _name
    ) BaseStrategy(_asset, _name) {
        IGhoToken(gho).approve(address(pool), type(uint256).max);
        ICurvePool(pool).approve(address(convex), type(uint256).max);
        IERC20(crv).approve(address(rewardsPool), type(uint256).max);
        IERC20(crvusd).approve(address(pool), type(uint256).max);
        convexToken.approve(address(cvxEthPool), type(uint256).max);
        IERC20(weth).approve(address(rewardsPool), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Should deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy should attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        // Deposit GHO into crvUSD/GHO pool.
        uint256[] memory _amounts = new uint256[](2);
        _amounts[0] = _amount;

        uint256 _expectedLpAmount = pool.calc_token_amount(_amounts, true);
        uint256 _minAmountOut = (_expectedLpAmount * 99) / 100;

        uint256 _lpAmount = pool.add_liquidity(_amounts, _minAmountOut);

        // Deposit crvUSDGHO LP into convex and stake.
        convex.deposit(PID, _lpAmount, true);
    }

    /**
     * @dev Will attempt to free the '_amount' of 'asset'.
     *
     * The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        // Unstake crvUSDGHO LP.
        uint256[] memory _amounts = new uint256[](2);
        _amounts[0] = _amount;
        uint256 _desired_lp_amount = pool.calc_token_amount(
            _amounts,
            false
        );

        uint256 _staked_tokens = convexRewards.balanceOf(address(this));

        uint256 _lp_amount = Math.min(_desired_lp_amount, _staked_tokens);

        if (_lp_amount == 0) revert ZeroLP();
        convexRewards.withdrawAndUnwrap(_lp_amount, false);

        uint256 _minAmountOut = (_amount * 99) / 100;

        // Withdraw GHO
        uint256 _out = pool.remove_liquidity_one_coin(
            _lp_amount,
            int128(0),
            _minAmountOut
        );
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        if (!TokenizedStrategy.isShutdown()) {
            // Claim CRV rewards
            bool _claimedSucessfully = convexRewards.getReward();
            if (!_claimedSucessfully) revert NoCRVMinted();
            
            uint256 dx = IERC20(crv).balanceOf(address(this));

            uint256 min_dy = (rewardsPool.get_dy(2, 0, dx) * 99) / 100;
            uint256 _amount = rewardsPool.exchange(2, 0, dx, min_dy);

            uint256[] memory _amounts = new uint256[](2);
            _amounts[1] = _amount;

            uint256 _expectedLpAmount = pool.calc_token_amount(_amounts, true);
            uint256 _minAmountOut = (_expectedLpAmount * 99) / 100;

            uint256 _lpAmount = pool.add_liquidity(_amounts, _minAmountOut);

            // Deposit crvUSDGHO LP into convex and stake.
            convex.deposit(PID, _lpAmount, true);
        }

        uint256 _convexLPBalance = convexRewards.balanceOf(address(this));
        uint256 _ghoBalance = IERC20(gho).balanceOf(address(this));

        // `calc_withdraw_one_coin` reverts when `_burn_amount` is zero
        if (_convexLPBalance == 0) {
            _totalAssets = _ghoBalance;
        }
        else {
            _totalAssets = 
                pool.calc_withdraw_one_coin(_convexLPBalance, int128(0)) + 
                IERC20(gho).balanceOf(address(this));
        }
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * The TokenizedStrategy contract will do all needed debt and idle updates
     * after this has finished and will have no effect on PPS of the strategy
     * till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     *
    */
    function _tend(uint256 _totalIdle) internal override {
        if (!_tendTrigger()) revert NotEnoughCVX();

	    uint256 cvxBalance = convexToken.balanceOf(address(this));

        uint256 _minAmount = (cvxEthPool.get_dy(1, 0, cvxBalance) * 99) / 100;
        uint256 ethAmount = cvxEthPool.exchange(1, 0, cvxBalance, _minAmount);
        rewardsPool.exchange(1, 2, ethAmount, 0);
    }

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     *
    */
    function _tendTrigger() internal view override returns (bool) {
	    uint256 cvxBalance = convexToken.balanceOf(address(this));

        if (cvxBalance == 0) return false;
	
        // CVX -> CRV via WETH
        uint256 ethAmount = cvxEthPool.get_dy(1, 0, cvxBalance);
        uint256 crvOut = rewardsPool.get_dy(1, 2, ethAmount);

        return crvOut > 30e18;
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     *
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        TODO: If desired Implement deposit limit logic and any needed state variables .
        
        EX:    
            uint256 totalAssets = TokenizedStrategy.totalAssets();
            return totalAssets >= depositLimit ? 0 : depositLimit - totalAssets;
    }
    */

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies. It should never be lower than `totalIdle`.
     *
     *   EX:
     *       return TokenIzedStrategy.totalIdle();
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     *
    function availableWithdrawLimit(
        address _owner
    ) public view override returns (uint256) {
        TODO: If desired Implement withdraw limit logic and any needed state variables.
        
        EX:    
            return TokenizedStrategy.totalIdle();
    }
    */

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     *
    function _emergencyWithdraw(uint256 _amount) internal override {
        TODO: If desired implement simple logic to free deployed funds.

        EX:
            _amount = min(_amount, aToken.balanceOf(address(this)));
            _freeFunds(_amount);
    }

    */
}
