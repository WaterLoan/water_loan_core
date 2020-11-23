pragma solidity ^0.5.0;

import "../../interfaces/ILendingRateOracle.sol";
import "../../libraries/openzeppelin-solidity/contracts/ownership/Ownable.sol";


contract LendingRateOracle is ILendingRateOracle, Ownable {

    mapping(address => uint256) borrowRates;
    mapping(address => uint256) liquidityRates;


    function getMarketBorrowRate(address _asset) external view returns(uint256) {
        return borrowRates[_asset];
    }

    function setMarketBorrowRate(address _asset, uint256 _rate) external {
        borrowRates[_asset] = _rate;
    }

    function getMarketLiquidityRate(address _asset) external view returns(uint256) {
        return liquidityRates[_asset];
    }

    function setMarketLiquidityRate(address _asset, uint256 _rate) external {
        liquidityRates[_asset] = _rate;
    }
}
