const DefaultStrategy = artifacts.require("DefaultStrategy");
const LendingPoolAddressesProvider = artifacts.require("LendingPoolAddressesProvider");
const LendingPoolConfigurator = artifacts.require("LendingPoolConfigurator");
const LendingPool = artifacts.require("LendingPool");

contract('LendingPoolConfigurator', async () => {
    it("Configurator initReserve success", async () => {
        let reserve = "TXka46PPwttNPWfFDPtt3GUodbPThyufaV";
        let configurator = await LendingPoolConfigurator.deployed();
        let strategy = await DefaultStrategy.deployed();
        let res = await configurator.initReserveWithData(reserve, "Water interest bearing TRX", "wTRX", 6, strategy.address);

        let lending_pool = await LendingPool.deployed();
        let res2 = await debug(lending_pool.getReserveData(reserve));
        console.log(res2);
    });
});
