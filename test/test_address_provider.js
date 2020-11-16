const LendingPoolCore = artifacts.require("LendingPoolCore");
const LendingPoolAddressesProvider = artifacts.require("LendingPoolAddressesProvider");

contract('LendingPoolAddressesProvider', async () => {
    it("address provider contract address should same", async () => {
        let core_instance = await LendingPoolCore.deployed();

        let instance = await LendingPoolAddressesProvider.deployed();
        let address = await instance.getLendingPoolCore();
        console.log(core_instance.address, address);

        assert.equal(core_instance.address, address, "address provider lending pool core contract address not same");
    });
});
