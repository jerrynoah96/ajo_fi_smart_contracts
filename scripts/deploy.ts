// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
import { ethers } from "hardhat";

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  // Deploy mock USDC and USDT first
  const TokenFactory = await ethers.getContractFactory("Token");
  const usdc = await TokenFactory.deploy();
  await usdc.deployed();
  console.log("Mock USDC deployed to:", usdc.address);

  const usdt = await TokenFactory.deploy();
  await usdt.deployed();
  console.log("Mock USDT deployed to:", usdt.address);

  // Deploy mock price oracle
  const MockPriceOracleFactory = await ethers.getContractFactory("MockPriceOracle");
  const priceOracle = await MockPriceOracleFactory.deploy();
  await priceOracle.deployed();
  console.log("Mock Price Oracle deployed to:", priceOracle.address);

  // Deploy Credit System
  const CreditSystemFactory = await ethers.getContractFactory("CreditSystem");
  const creditSystem = await CreditSystemFactory.deploy(
    usdc.address,
    usdt.address,
    priceOracle.address
  );
  await creditSystem.deployed();
  console.log("Credit System deployed to:", creditSystem.address);

  // Deploy Purse Factory
  const PurseFactoryFactory = await ethers.getContractFactory("PurseFactory");
  const purseFactory = await PurseFactoryFactory.deploy(creditSystem.address);
  await purseFactory.deployed();
  console.log("Purse Factory deployed to:", purseFactory.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
