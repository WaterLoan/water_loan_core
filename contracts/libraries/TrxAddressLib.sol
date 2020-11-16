pragma solidity ^0.5.0;

library TrxAddressLib {

    /**
    * @dev returns the address used within the protocol to identify ETH
    * @return the address assigned to ETH
     */
    function trxAddress() internal pure returns(address) {
        return 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    }
}
