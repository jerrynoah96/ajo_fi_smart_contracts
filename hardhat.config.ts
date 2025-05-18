import * as dotenv from "dotenv";
import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomiclabs/hardhat-ethers";
import "@typechain/hardhat";
import "hardhat-gas-reporter";
import "solidity-coverage";
import { task } from "hardhat/config";

// Load environment variables
dotenv.config();

// Define private key from env or use a default array for localhost testing
const PRIVATE_KEY = process.env.PRIVATE_KEY || "0x0000000000000000000000000000000000000000000000000000000000000000";
// Use demo API keys if not provided (only for development)
const ALCHEMY_API_KEY = process.env.ALCHEMY_API_KEY || "";
const ETHERSCAN_API_KEY = process.env.ETHERSCAN_API_KEY || "";

// This is a sample Hardhat task
task("accounts", "Prints the list of accounts", async (taskArgs, hre) => {
  const accounts = await hre.ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

// Configuration
const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.29",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200
          },
          evmVersion: "paris"
        }
      }
    ]
  },
  networks: {
    // Local development networks
    hardhat: {
      forking: process.env.FORK_MAINNET === "true" && ALCHEMY_API_KEY ? {
        url: `https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}`,
        blockNumber: 19000000,
      } : undefined,
      chainId: 31337,
      mining: {
        auto: true,
        interval: 0
      }
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 31337,
    },
    
    // Test networks
    sepolia: {
      url: process.env.SEPOLIA_URL || (ALCHEMY_API_KEY ? `https://eth-sepolia.g.alchemy.com/v2/${ALCHEMY_API_KEY}` : "https://rpc.sepolia.org"),
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
      chainId: 11155111,
      gas: 2100000,
      gasPrice: 8000000000,
      timeout: 60000
    },
    baseSepolia: {
      url: process.env.BASE_SEPOLIA_URL || "https://sepolia.base.org",
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
      chainId: 84532,
      gas: 2100000,
      gasPrice: 8000000000,
      timeout: 60000
    }
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS === "true",
    currency: "USD",
    outputFile: process.env.GAS_REPORT_OUTPUT_FILE || "",
    noColors: process.env.GAS_REPORT_NO_COLORS === "true",
    token: "ETH",
    gasPriceApi: process.env.GAS_PRICE_API
  },
  etherscan: {
    apiKey: ETHERSCAN_API_KEY,
  },
  typechain: {
    outDir: "typechain",
    target: "ethers-v5"
  },
  mocha: {
    timeout: 100000
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  }
};

// Only add mainnet if explicitly enabled
if (process.env.ENABLE_MAINNET === "true") {
  config.networks!.mainnet = {
    url: process.env.MAINNET_URL || (ALCHEMY_API_KEY ? `https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}` : "https://ethereum.publicnode.com"),
    accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    chainId: 1,
    gasPrice: "auto",
    timeout: 120000
  };
}

export default config;
