// Network configurations and constants
export type NetworkConfig = {
  name: string;
  blockConfirmations?: number;
}

export type NetworkConfigMap = {
  [chainId: string]: NetworkConfig
}

export const networkConfig: NetworkConfigMap = {
  "31337": {
    name: "localhost",
    blockConfirmations: 1,
  },
  "11155111": {
    name: "sepolia",
    blockConfirmations: 6,
  },
  "1": {
    name: "mainnet",
    blockConfirmations: 12,
  }
}

// Development constants
export const developmentChains = ["hardhat", "localhost"]
export const DECIMALS = "8"
export const INITIAL_PRICE = "200000000000" // 2000 USD with 8 decimals

// Contract values
export const MIN_STAKE_AMOUNT = "1000000000000000000000" // 1000 tokens
export const MAX_FEE_PERCENTAGE = 50 // 0.5%
export const ROUND_INTERVAL = 86400 // 1 day in seconds
export const MAX_DELAY_TIME = 604800 // 1 week in seconds 