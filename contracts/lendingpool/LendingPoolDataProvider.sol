pragma solidity ^0.5.0;

import "../libraries/openzeppelin-solidity/contracts/math/SafeMath.sol";
import "../libraries/openzeppelin-upgradeability/VersionedInitializable.sol";

import "../libraries/CoreLibrary.sol";
import "../configuration/LendingPoolAddressesProvider.sol";
import "../libraries/WadRayMath.sol";
import "../interfaces/IPriceOracleGetter.sol";
import "../interfaces/IFeeProvider.sol";
import "../tokenization/AToken.sol";

import "./LendingPoolCore.sol";

/**
* @title LendingPoolDataProvider contract
* @author Aave
* @notice Implements functions to fetch data from the core, and aggregate them in order to allow computation
* on the compounded balances and the account balances in TRX
**/
contract LendingPoolDataProvider is VersionedInitializable {
    using SafeMath for uint256;
    using WadRayMath for uint256;

    LendingPoolCore public core;
    LendingPoolAddressesProvider public addressesProvider;

    /**
    * @dev specifies the health factor threshold at which the user position is liquidated.
    * 1e18 by default, if the health factor drops below 1e18, the loan can be liquidated.
    **/
    uint256 public constant HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18;

    uint256 public constant DATA_PROVIDER_REVISION = 0x1;

    function getRevision() internal pure returns (uint256) {
        return DATA_PROVIDER_REVISION;
    }

    function initialize(LendingPoolAddressesProvider _addressesProvider) public initializer {
        addressesProvider = _addressesProvider;
        core = LendingPoolCore(_addressesProvider.getLendingPoolCore());
    }

    /**
    * @dev struct to hold calculateUserGlobalData() local computations
    **/
    struct UserGlobalDataLocalVars {
        uint256 reserveUnitPrice;
        uint256 tokenUnit;
        uint256 compoundedLiquidityBalance;
        uint256 compoundedBorrowBalance;
        uint256 reserveDecimals;
        uint256 baseLtv;
        uint256 liquidationThreshold;
        uint256 originationFee;
        bool usageAsCollateralEnabled;
        bool userUsesReserveAsCollateral;
        address currentReserve;
    }

    /**
    * @dev calculates the user data across the reserves.
    * this includes the total liquidity/collateral/borrow balances in TRX,
    * the average Loan To Value, the average Liquidation Ratio, and the Health factor.
    * @param _user the address of the user
    * @return the total liquidity, total collateral, total borrow balances of the user in TRX.
    * also the average Ltv, liquidation threshold, and the health factor
    **/
    function calculateUserGlobalData(address _user)
        public
        view
        returns (
            uint256 totalLiquidityBalanceTRX,
            uint256 totalCollateralBalanceTRX,
            uint256 totalBorrowBalanceTRX,
            uint256 totalFeesTRX,
            uint256 currentLtv,
            uint256 currentLiquidationThreshold,
            uint256 healthFactor,
            bool healthFactorBelowThreshold
        )
    {
        IPriceOracleGetter oracle = IPriceOracleGetter(addressesProvider.getPriceOracle());

        // Usage of a memory struct of vars to avoid "Stack too deep" errors due to local variables
        UserGlobalDataLocalVars memory vars;

        address[] memory reserves = core.getReserves();

        for (uint256 i = 0; i < reserves.length; i++) {
            vars.currentReserve = reserves[i];

            (
                vars.compoundedLiquidityBalance,
                vars.compoundedBorrowBalance,
                vars.originationFee,
                vars.userUsesReserveAsCollateral
            ) = core.getUserBasicReserveData(vars.currentReserve, _user);

            if (vars.compoundedLiquidityBalance == 0 && vars.compoundedBorrowBalance == 0) {
                continue;
            }

            //fetch reserve data
            (
                vars.reserveDecimals,
                vars.baseLtv,
                vars.liquidationThreshold,
                vars.usageAsCollateralEnabled
            ) = core.getReserveConfiguration(vars.currentReserve);

            vars.tokenUnit = 10 ** vars.reserveDecimals;
            vars.reserveUnitPrice = oracle.getAssetPrice(vars.currentReserve);

            //liquidity and collateral balance
            if (vars.compoundedLiquidityBalance > 0) {
                uint256 liquidityBalanceTRX = vars
                    .reserveUnitPrice
                    .mul(vars.compoundedLiquidityBalance)
                    .div(vars.tokenUnit);
                totalLiquidityBalanceTRX = totalLiquidityBalanceTRX.add(liquidityBalanceTRX);

                if (vars.usageAsCollateralEnabled && vars.userUsesReserveAsCollateral) {
                    totalCollateralBalanceTRX = totalCollateralBalanceTRX.add(liquidityBalanceTRX);
                    currentLtv = currentLtv.add(liquidityBalanceTRX.mul(vars.baseLtv));
                    currentLiquidationThreshold = currentLiquidationThreshold.add(
                        liquidityBalanceTRX.mul(vars.liquidationThreshold)
                    );
                }
            }

            if (vars.compoundedBorrowBalance > 0) {
                totalBorrowBalanceTRX = totalBorrowBalanceTRX.add(
                    vars.reserveUnitPrice.mul(vars.compoundedBorrowBalance).div(vars.tokenUnit)
                );
                totalFeesTRX = totalFeesTRX.add(
                    vars.originationFee.mul(vars.reserveUnitPrice).div(vars.tokenUnit)
                );
            }
        }

        currentLtv = totalCollateralBalanceTRX > 0 ? currentLtv.div(totalCollateralBalanceTRX) : 0;
        currentLiquidationThreshold = totalCollateralBalanceTRX > 0
            ? currentLiquidationThreshold.div(totalCollateralBalanceTRX)
            : 0;

        healthFactor = calculateHealthFactorFromBalancesInternal(
            totalCollateralBalanceTRX,
            totalBorrowBalanceTRX,
            totalFeesTRX,
            currentLiquidationThreshold
        );
        healthFactorBelowThreshold = healthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD;

    }

    struct balanceDecreaseAllowedLocalVars {
        uint256 decimals;
        uint256 collateralBalanceTRX;
        uint256 borrowBalanceTRX;
        uint256 totalFeesTRX;
        uint256 currentLiquidationThreshold;
        uint256 reserveLiquidationThreshold;
        uint256 amountToDecreaseTRX;
        uint256 collateralBalancefterDecrease;
        uint256 liquidationThresholdAfterDecrease;
        uint256 healthFactorAfterDecrease;
        bool reserveUsageAsCollateralEnabled;
    }

    /**
    * @dev check if a specific balance decrease is allowed (i.e. doesn't bring the user borrow position health factor under 1e18)
    * @param _reserve the address of the reserve
    * @param _user the address of the user
    * @param _amount the amount to decrease
    * @return true if the decrease of the balance is allowed
    **/

    function balanceDecreaseAllowed(address _reserve, address _user, uint256 _amount)
        external
        view
        returns (bool)
    {
        // Usage of a memory struct of vars to avoid "Stack too deep" errors due to local variables
        balanceDecreaseAllowedLocalVars memory vars;

        (
            vars.decimals,
            ,
            vars.reserveLiquidationThreshold,
            vars.reserveUsageAsCollateralEnabled
        ) = core.getReserveConfiguration(_reserve);

        if (
            !vars.reserveUsageAsCollateralEnabled ||
            !core.isUserUseReserveAsCollateralEnabled(_reserve, _user)
        ) {
            return true; //if reserve is not used as collateral, no reasons to block the transfer
        }

        (
            ,
            vars.collateralBalanceTRX,
            vars.borrowBalanceTRX,
            vars.totalFeesTRX,
            ,
            vars.currentLiquidationThreshold,
            ,

        ) = calculateUserGlobalData(_user);

        if (vars.borrowBalanceTRX == 0) {
            return true; //no borrows - no reasons to block the transfer
        }

        IPriceOracleGetter oracle = IPriceOracleGetter(addressesProvider.getPriceOracle());

        vars.amountToDecreaseTRX = oracle.getAssetPrice(_reserve).mul(_amount).div(
            10 ** vars.decimals
        );

        vars.collateralBalancefterDecrease = vars.collateralBalanceTRX.sub(
            vars.amountToDecreaseTRX
        );

        //if there is a borrow, there can't be 0 collateral
        if (vars.collateralBalancefterDecrease == 0) {
            return false;
        }

        vars.liquidationThresholdAfterDecrease = vars
            .collateralBalanceTRX
            .mul(vars.currentLiquidationThreshold)
            .sub(vars.amountToDecreaseTRX.mul(vars.reserveLiquidationThreshold))
            .div(vars.collateralBalancefterDecrease);

        uint256 healthFactorAfterDecrease = calculateHealthFactorFromBalancesInternal(
            vars.collateralBalancefterDecrease,
            vars.borrowBalanceTRX,
            vars.totalFeesTRX,
            vars.liquidationThresholdAfterDecrease
        );

        return healthFactorAfterDecrease > HEALTH_FACTOR_LIQUIDATION_THRESHOLD;

    }

    /**
   * @notice calculates the amount of collateral needed in TRX to cover a new borrow.
   * @param _reserve the reserve from which the user wants to borrow
   * @param _amount the amount the user wants to borrow
   * @param _fee the fee for the amount that the user needs to cover
   * @param _userCurrentBorrowBalanceTH the current borrow balance of the user (before the borrow)
   * @param _userCurrentLtv the average ltv of the user given his current collateral
   * @return the total amount of collateral in TRX to cover the current borrow balance + the new amount + fee
   **/
    function calculateCollateralNeededInTRX(
        address _reserve,
        uint256 _amount,
        uint256 _fee,
        uint256 _userCurrentBorrowBalanceTH,
        uint256 _userCurrentFeesTRX,
        uint256 _userCurrentLtv
    ) external view returns (uint256) {
        uint256 reserveDecimals = core.getReserveDecimals(_reserve);

        IPriceOracleGetter oracle = IPriceOracleGetter(addressesProvider.getPriceOracle());

        uint256 requestedBorrowAmountTRX = oracle
            .getAssetPrice(_reserve)
            .mul(_amount.add(_fee))
            .div(10 ** reserveDecimals); //price is in ether

        //add the current already borrowed amount to the amount requested to calculate the total collateral needed.
        uint256 collateralNeededInTRX = _userCurrentBorrowBalanceTH
            .add(_userCurrentFeesTRX)
            .add(requestedBorrowAmountTRX)
            .mul(100)
            .div(_userCurrentLtv); //LTV is calculated in percentage

        return collateralNeededInTRX;

    }

    /**
    * @dev calculates the equivalent amount in TRX that an user can borrow, depending on the available collateral and the
    * average Loan To Value.
    * @param collateralBalanceTRX the total collateral balance
    * @param borrowBalanceTRX the total borrow balance
    * @param totalFeesTRX the total fees
    * @param ltv the average loan to value
    * @return the amount available to borrow in TRX for the user
    **/

    function calculateAvailableBorrowsTRXInternal(
        uint256 collateralBalanceTRX,
        uint256 borrowBalanceTRX,
        uint256 totalFeesTRX,
        uint256 ltv
    ) internal view returns (uint256) {
        uint256 availableBorrowsTRX = collateralBalanceTRX.mul(ltv).div(100); //ltv is in percentage

        if (availableBorrowsTRX < borrowBalanceTRX) {
            return 0;
        }

        availableBorrowsTRX = availableBorrowsTRX.sub(borrowBalanceTRX.add(totalFeesTRX));
        //calculate fee
        uint256 borrowFee = IFeeProvider(addressesProvider.getFeeProvider())
            .calculateLoanOriginationFee(msg.sender, availableBorrowsTRX);
        return availableBorrowsTRX.sub(borrowFee);
    }

    /**
    * @dev calculates the health factor from the corresponding balances
    * @param collateralBalanceTRX the total collateral balance in TRX
    * @param borrowBalanceTRX the total borrow balance in TRX
    * @param totalFeesTRX the total fees in TRX
    * @param liquidationThreshold the avg liquidation threshold
    **/
    function calculateHealthFactorFromBalancesInternal(
        uint256 collateralBalanceTRX,
        uint256 borrowBalanceTRX,
        uint256 totalFeesTRX,
        uint256 liquidationThreshold
    ) internal pure returns (uint256) {
        if (borrowBalanceTRX == 0) return uint256(-1);

        return
            (collateralBalanceTRX.mul(liquidationThreshold).div(100)).wadDiv(
                borrowBalanceTRX.add(totalFeesTRX)
            );
    }

    /**
    * @dev returns the health factor liquidation threshold
    **/
    function getHealthFactorLiquidationThreshold() public pure returns (uint256) {
        return HEALTH_FACTOR_LIQUIDATION_THRESHOLD;
    }

    /**
    * @dev accessory functions to fetch data from the lendingPoolCore
    **/
    function getReserveConfigurationData(address _reserve)
        external
        view
        returns (
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            address rateStrategyAddress,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive
        )
    {
        (, ltv, liquidationThreshold, usageAsCollateralEnabled) = core.getReserveConfiguration(
            _reserve
        );
        stableBorrowRateEnabled = core.getReserveIsStableBorrowRateEnabled(_reserve);
        borrowingEnabled = core.isReserveBorrowingEnabled(_reserve);
        isActive = core.getReserveIsActive(_reserve);
        liquidationBonus = core.getReserveLiquidationBonus(_reserve);

        rateStrategyAddress = core.getReserveInterestRateStrategyAddress(_reserve);
    }

    function getReserveData(address _reserve)
        external
        view
        returns (
            uint256 totalLiquidity,
            uint256 availableLiquidity,
            uint256 totalBorrowsStable,
            uint256 totalBorrowsVariable,
            uint256 liquidityRate,
            uint256 variableBorrowRate,
            uint256 stableBorrowRate,
            uint256 averageStableBorrowRate,
            uint256 utilizationRate,
            uint256 liquidityIndex,
            uint256 variableBorrowIndex,
            address aTokenAddress,
            uint40 lastUpdateTimestamp
        )
    {
        totalLiquidity = core.getReserveTotalLiquidity(_reserve);
        availableLiquidity = core.getReserveAvailableLiquidity(_reserve);
        totalBorrowsStable = core.getReserveTotalBorrowsStable(_reserve);
        totalBorrowsVariable = core.getReserveTotalBorrowsVariable(_reserve);
        liquidityRate = core.getReserveCurrentLiquidityRate(_reserve);
        variableBorrowRate = core.getReserveCurrentVariableBorrowRate(_reserve);
        stableBorrowRate = core.getReserveCurrentStableBorrowRate(_reserve);
        averageStableBorrowRate = core.getReserveCurrentAverageStableBorrowRate(_reserve);
        utilizationRate = core.getReserveUtilizationRate(_reserve);
        liquidityIndex = core.getReserveLiquidityCumulativeIndex(_reserve);
        variableBorrowIndex = core.getReserveVariableBorrowsCumulativeIndex(_reserve);
        aTokenAddress = core.getReserveATokenAddress(_reserve);
        lastUpdateTimestamp = core.getReserveLastUpdate(_reserve);
    }

    function getUserAccountData(address _user)
        external
        view
        returns (
            uint256 totalLiquidityTRX,
            uint256 totalCollateralTRX,
            uint256 totalBorrowsTRX,
            uint256 totalFeesTRX,
            uint256 availableBorrowsTRX,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        (
            totalLiquidityTRX,
            totalCollateralTRX,
            totalBorrowsTRX,
            totalFeesTRX,
            ltv,
            currentLiquidationThreshold,
            healthFactor,

        ) = calculateUserGlobalData(_user);

        availableBorrowsTRX = calculateAvailableBorrowsTRXInternal(
            totalCollateralTRX,
            totalBorrowsTRX,
            totalFeesTRX,
            ltv
        );
    }

    function getUserReserveData(address _reserve, address _user)
        external
        view
        returns (
            uint256 currentATokenBalance,
            uint256 currentBorrowBalance,
            uint256 principalBorrowBalance,
            uint256 borrowRateMode,
            uint256 borrowRate,
            uint256 liquidityRate,
            uint256 originationFee,
            uint256 variableBorrowIndex,
            uint256 lastUpdateTimestamp,
            bool usageAsCollateralEnabled
        )
    {
        currentATokenBalance = AToken(core.getReserveATokenAddress(_reserve)).balanceOf(_user);
        CoreLibrary.InterestRateMode mode = core.getUserCurrentBorrowRateMode(_reserve, _user);
        (principalBorrowBalance, currentBorrowBalance, ) = core.getUserBorrowBalances(
            _reserve,
            _user
        );

        //default is 0, if mode == CoreLibrary.InterestRateMode.NONE
        if (mode == CoreLibrary.InterestRateMode.STABLE) {
            borrowRate = core.getUserCurrentStableBorrowRate(_reserve, _user);
        } else if (mode == CoreLibrary.InterestRateMode.VARIABLE) {
            borrowRate = core.getReserveCurrentVariableBorrowRate(_reserve);
        }

        borrowRateMode = uint256(mode);
        liquidityRate = core.getReserveCurrentLiquidityRate(_reserve);
        originationFee = core.getUserOriginationFee(_reserve, _user);
        variableBorrowIndex = core.getUserVariableBorrowCumulativeIndex(_reserve, _user);
        lastUpdateTimestamp = core.getUserLastUpdate(_reserve, _user);
        usageAsCollateralEnabled = core.isUserUseReserveAsCollateralEnabled(_reserve, _user);
    }
}
