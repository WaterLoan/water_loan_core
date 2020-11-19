pragma solidity ^0.5.0;

import "../../interfaces/IPriceOracle.sol";
import "../../libraries/openzeppelin-solidity/contracts/ownership/Ownable.sol";


contract PriceOracle is IPriceOracle, Ownable {

    mapping(address => uint256) prices;
    uint256 trxPriceUsd;

    event AssetPriceUpdated(address _asset, uint256 _price, uint256 timestamp);
    event TrxPriceUpdated(uint256 _price, uint256 timestamp);

    function getAssetPrice(address _asset) external view returns(uint256) {
        return prices[_asset];
    }

    function setAssetPrice(address _asset, uint256 _price) external {
        prices[_asset] = _price;
        emit AssetPriceUpdated(_asset, _price, block.timestamp);
    }

    function getTrxUsdPrice() external view returns(uint256) {
        return trxPriceUsd;
    }

    function setTrxUsdPrice(uint256 _price) external {
        trxPriceUsd = _price;
        emit TrxPriceUpdated(_price, block.timestamp);
    }
}
