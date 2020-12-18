pragma solidity ^0.5.0;

import "../libraries/openzeppelin-solidity/contracts/math/SafeMath.sol";
import "../libraries/openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "../libraries/openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";
import "../libraries/openzeppelin-solidity/contracts/token/ERC20/ERC20Burnable.sol";

import "../libraries/openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "../libraries/TrxAddressLib.sol";


/// @title TokenDistributor
/// @author Aave
/// @notice Receives tokens and manages the distribution amongst receivers
///  The usage is as follows:
///  - The distribution addresses and percentages are set up on construction
///  - The Swap Proxy is approved for a list of tokens in construction, which will be later burnt
///  - At any moment, anyone can call distribute() with a list of token addresses in order to distribute
///    the accumulated token amounts and/or TRX in this contract to all the receivers with percentages
///  - If the address(0) is used as receiver, this contract will trade in JustSwap to tokenToBurn
///    and burn it (sending to address(0) the tokenToBurn)
contract TokenDistributor is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Distribution {
        address[] receivers;
        uint256[] percentages;
    }

    event DistributionUpdated(address[] receivers, uint256[] percentages);
    event Distributed(address receiver, uint256 percentage, uint256 amount);

    uint256 public constant IMPLEMENTATION_REVISION = 0x1;

    /// @notice Defines how tokens and TRX are distributed on each call to .distribute()
    Distribution private distribution;

    /// @notice Instead of using 100 for percentages, higher base to have more precision in the distribution
    uint256 public constant DISTRIBUTION_BASE = 10000;

    /// @notice Called by the proxy when setting this contract as implementation
    function setTokenDistribution(
        address[] memory _receivers,
        uint256[] memory _percentages
    ) public onlyOwner {
        internalSetTokenDistribution(_receivers, _percentages);
    }

    /// @notice In order to receive TRX transfers
    function() external payable {}

    /// @notice Distributes a list of _tokens balances in this contract, depending on the distribution
    /// @param _tokens list of ERC20 tokens to distribute
    function distribute(IERC20[] memory _tokens) public {
        for (uint256 i = 0; i < _tokens.length; i++) {
            address _tokenAddress = address(_tokens[i]);
            uint256 _balanceToDistribute = (_tokenAddress != TrxAddressLib.trxAddress())
                ? _tokens[i].balanceOf(address(this))
                : address(this).balance;
            if (_balanceToDistribute <= 0) {
                continue;
            }

            Distribution memory _distribution = distribution;
            for (uint256 j = 0; j < _distribution.receivers.length; j++) {
                uint256 _amount = _balanceToDistribute.mul(_distribution.percentages[j]).div(DISTRIBUTION_BASE);
                if (_distribution.receivers[j] != address(0)) {
                    if (_tokenAddress != TrxAddressLib.trxAddress()) {
                        _tokens[i].safeTransfer(_distribution.receivers[j], _amount);
                    } else {
                        (bool _success,) = _distribution.receivers[j].call.value(_amount)("");
                        require(_success, "Reverted TRX transfer");
                    }
                    emit Distributed(_distribution.receivers[j], _distribution.percentages[j], _amount);
                }
            }
        }
    }

    /// @notice Returns the receivers and percentages of the contract Distribution
    /// @return receivers array of addresses and percentages array on uints
    function getDistribution() public view returns(address[] memory receivers, uint256[] memory percentages) {
        receivers = distribution.receivers;
        percentages = distribution.percentages;
    }

    /// @notice Gets the revision number of the contract
    /// @return The revision numeric reference
    function getRevision() internal pure returns (uint256) {
        return IMPLEMENTATION_REVISION;
    }

    /// @notice Sets _receivers addresses with _percentages for each one
    /// @param _receivers Array of addresses receiving a percentage of the distribution, both user addresses
    ///   or contracts
    /// @param _percentages Array of percentages each _receivers member will get
    function internalSetTokenDistribution(address[] memory _receivers, uint256[] memory _percentages) internal {
        require(_receivers.length == _percentages.length, "Array lengths should be equal");

        distribution = Distribution({receivers: _receivers, percentages: _percentages});
        emit DistributionUpdated(_receivers, _percentages);
    }
    
    /// This method is called if the contract needs to be changed
    function exitAsset(address _tokenAddress) public onlyOwner {
        uint256 _balanceToDistribute = (_tokenAddress != TrxAddressLib.trxAddress())
            ? IERC20(_tokenAddress).balanceOf(address(this))
            : address(this).balance;
        if (_balanceToDistribute > 0) {
            if (_tokenAddress != TrxAddressLib.trxAddress()) {
                IERC20(_tokenAddress).transfer(owner(), _balanceToDistribute);
            } else {
                (bool _success,) = owner().call.value(_balanceToDistribute)("");
                require(_success, "Reverted TRX transfer");
            }
        }
    }

}
