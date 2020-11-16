const LendingPoolParametersProvider = artifacts.require("LendingPoolParametersProvider");

contract('LendingPoolParametersProvider', async () => {
    it("max borrow", async () => {
        let instance = await LendingPoolParametersProvider.deployed();
        let max_borrow = await instance.getMaxStableRateBorrowSizePercent();
        console.log('max_borrow', max_borrow.toString());
        assert.equal(max_borrow.toString(), '25', "max borrow not same");
    });
});

