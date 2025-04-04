// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
import { ethers } from "hardhat";
import * as dotenv from "dotenv";
dotenv.config();

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

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
  }

  // Deploy TokenRegistry
  const TokenRegistryFactory = await ethers.getContractFactory("TokenRegistry");
  const tokenRegistry = await TokenRegistryFactory.deploy();
  await tokenRegistry.deployed();
  console.log("Token Registry deployed to:", tokenRegistry.address);

  // Whitelist token in registry
  if (!(await tokenRegistry.isTokenWhitelisted(token.address))) {
    await tokenRegistry.connect(deployer).setTokenWhitelist(token.address, true);
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

  // Deploy ValidatorFactory
  const ValidatorFactoryFactory = await ethers.getContractFactory("ValidatorFactory");
  const validatorFactory = await ValidatorFactoryFactory.deploy(
    creditSystem.address,
    ethers.utils.parseUnits("1000", "ether"), // min stake
    50, // max fee percentage (0.5%)
    token.address // default whitelisted token
  );
  await validatorFactory.deployed();
  console.log("Validator Factory deployed to:", validatorFactory.address);

  // Update CreditSystem with ValidatorFactory
  await creditSystem.connect(deployer).authorizeFactory(validatorFactory.address, true);
  console.log("Validator Factory authorized in Credit System");

  // Deploy PurseFactory
  const PurseFactoryFactory = await ethers.getContractFactory("PurseFactory");
  const purseFactory = await PurseFactoryFactory.deploy(
    creditSystem.address,
    validatorFactory.address
  );
  await purseFactory.deployed();
  console.log("Purse Factory deployed to:", purseFactory.address);

  // Setup access control
  const ADMIN_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ADMIN_ROLE"));
  
  // Authorize PurseFactory in CreditSystem
  await creditSystem.connect(deployer).authorizeFactory(purseFactory.address, false);
  console.log("Purse Factory authorized in Credit System");

  // Only mint tokens if we deployed a new token
  if (!process.env.TOKEN_ADDRESS) {
    // Mint some initial tokens to deployer
    await token.connect(deployer).mint(
      deployer.address, 
      ethers.utils.parseUnits("1000000", "ether")
    );
    console.log("Initial tokens minted to deployer");
  }

  console.log("\nDeployment Summary:");
  console.log("------------------");
  console.log("Token:", token.address);
  console.log("Token Registry:", tokenRegistry.address);
  console.log("Credit System:", creditSystem.address);
  console.log("Validator Factory:", validatorFactory.address);
  console.log("Purse Factory:", purseFactory.address);

  // Save deployed addresses to .env file
  const fs = require('fs');
  const envContent = `
TOKEN_ADDRESS=${token.address}
TOKEN_REGISTRY_ADDRESS=${tokenRegistry.address}
CREDIT_SYSTEM_ADDRESS=${creditSystem.address}
VALIDATOR_FACTORY_ADDRESS=${validatorFactory.address}
PURSE_FACTORY_ADDRESS=${purseFactory.address}
`;
  fs.appendFileSync('.env', envContent);
  console.log("\nContract addresses appended to .env file");
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
