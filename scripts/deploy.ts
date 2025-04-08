// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
import { ethers, network } from "hardhat";
import * as dotenv from "dotenv";
import { developmentChains, networkConfig, MIN_STAKE_AMOUNT, MAX_FEE_PERCENTAGE } from "../helper-hardhat-config";
import { verify } from "./verify";
dotenv.config();

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Network:", network.name);

  const chainId = network.config.chainId?.toString() || "31337";
  const blockConfirmations = networkConfig[chainId]?.blockConfirmations || 1;
  const waitConfirmations = developmentChains.includes(network.name) ? 1 : blockConfirmations;

  let token;
  // Check if we should use existing token or deploy new one
  if (process.env.TOKEN_ADDRESS) {
    console.log("Using existing token at:", process.env.TOKEN_ADDRESS);
    token = await ethers.getContractAt("MockERC20", process.env.TOKEN_ADDRESS);
  } else {
    // Deploy mock token
    console.log("Deploying new mock token...");
    const TokenFactory = await ethers.getContractFactory("MockERC20");
    token = await TokenFactory.deploy("Test Token", "TEST", 18);
    await token.deployed();
    console.log("Mock Token deployed to:", token.address);

    // Verify contract if not on a development chain
    if (!developmentChains.includes(network.name) && process.env.ETHERSCAN_API_KEY) {
      console.log("Verifying token...");
      await token.deployTransaction.wait(waitConfirmations);
      await verify(token.address, ["Test Token", "TEST", 18]);
    }
  }

  // Deploy TokenRegistry
  const TokenRegistryFactory = await ethers.getContractFactory("TokenRegistry");
  const tokenRegistry = await TokenRegistryFactory.deploy();
  await tokenRegistry.deployed();
  console.log("Token Registry deployed to:", tokenRegistry.address);

  // Verify contract if not on a development chain
  if (!developmentChains.includes(network.name) && process.env.ETHERSCAN_API_KEY) {
    console.log("Verifying token registry...");
    await tokenRegistry.deployTransaction.wait(waitConfirmations);
    await verify(tokenRegistry.address, []);
  }

  // Whitelist token in registry
  if (!(await tokenRegistry.isTokenWhitelisted(token.address))) {
    const tx = await tokenRegistry.connect(deployer).setTokenWhitelist(token.address, true);
    await tx.wait(1);
    console.log("Token whitelisted in registry");
  }

  // Deploy CreditSystem first with temporary null validator factory
  const CreditSystemFactory = await ethers.getContractFactory("CreditSystem");
  const creditSystem = await CreditSystemFactory.deploy(
    ethers.constants.AddressZero, // Temporary null address
    tokenRegistry.address
  );
  await creditSystem.deployed();
  console.log("Credit System deployed to:", creditSystem.address);

  // Verify contract if not on a development chain
  if (!developmentChains.includes(network.name) && process.env.ETHERSCAN_API_KEY) {
    console.log("Verifying credit system...");
    await creditSystem.deployTransaction.wait(waitConfirmations);
    await verify(creditSystem.address, [ethers.constants.AddressZero, tokenRegistry.address]);
  }

  // Deploy ValidatorFactory
  const ValidatorFactoryFactory = await ethers.getContractFactory("ValidatorFactory");
  const validatorFactory = await ValidatorFactoryFactory.deploy(
    creditSystem.address,
    MIN_STAKE_AMOUNT, // min stake from config
    MAX_FEE_PERCENTAGE, // max fee percentage from config
    tokenRegistry.address // token registry instead of token
  );
  await validatorFactory.deployed();
  console.log("Validator Factory deployed to:", validatorFactory.address);

  // Verify contract if not on a development chain
  if (!developmentChains.includes(network.name) && process.env.ETHERSCAN_API_KEY) {
    console.log("Verifying validator factory...");
    await validatorFactory.deployTransaction.wait(waitConfirmations);
    await verify(validatorFactory.address, [
      creditSystem.address,
      MIN_STAKE_AMOUNT,
      MAX_FEE_PERCENTAGE,
      tokenRegistry.address
    ]);
  }

  // Update CreditSystem with ValidatorFactory
  const authTx = await creditSystem.connect(deployer).authorizeFactory(validatorFactory.address, true);
  await authTx.wait(1);
  console.log("Validator Factory authorized in Credit System");

  // Deploy PurseFactory
  const PurseFactoryFactory = await ethers.getContractFactory("PurseFactory");
  const purseFactory = await PurseFactoryFactory.deploy(
    creditSystem.address,
    validatorFactory.address
  );
  await purseFactory.deployed();
  console.log("Purse Factory deployed to:", purseFactory.address);

  // Verify contract if not on a development chain
  if (!developmentChains.includes(network.name) && process.env.ETHERSCAN_API_KEY) {
    console.log("Verifying purse factory...");
    await purseFactory.deployTransaction.wait(waitConfirmations);
    await verify(purseFactory.address, [creditSystem.address, validatorFactory.address]);
  }
  
  // Authorize PurseFactory in CreditSystem
  const authPurseTx = await creditSystem.connect(deployer).authorizeFactory(purseFactory.address, false);
  await authPurseTx.wait(1);
  console.log("Purse Factory authorized in Credit System");

  // Only mint tokens if we deployed a new token
  if (!process.env.TOKEN_ADDRESS) {
    // Mint some initial tokens to deployer
    const mintTx = await token.connect(deployer).mint(
      deployer.address, 
      ethers.utils.parseUnits("1000000", "ether")
    );
    await mintTx.wait(1);
    console.log("Initial tokens minted to deployer");
  }

  console.log("\nDeployment Summary:");
  console.log("------------------");
  console.log("Network:", network.name);
  console.log("Token:", token.address);
  console.log("Token Registry:", tokenRegistry.address);
  console.log("Credit System:", creditSystem.address);
  console.log("Validator Factory:", validatorFactory.address);
  console.log("Purse Factory:", purseFactory.address);

  // Save deployed addresses to .env file
  // Only append to .env in development to avoid overwriting production addresses
  if (developmentChains.includes(network.name)) {
    const fs = require('fs');
    const envContent = `
# Deployed Contracts (${network.name})
TOKEN_ADDRESS=${token.address}
TOKEN_REGISTRY_ADDRESS=${tokenRegistry.address}
CREDIT_SYSTEM_ADDRESS=${creditSystem.address}
VALIDATOR_FACTORY_ADDRESS=${validatorFactory.address}
PURSE_FACTORY_ADDRESS=${purseFactory.address}
`;
    fs.appendFileSync('.env', envContent);
    console.log("\nContract addresses appended to .env file");
  }
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
