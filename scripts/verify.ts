import { run } from "hardhat";

/**
 * Verifies a contract on Etherscan
 * @param contractAddress The address of the contract to verify
 * @param args The constructor arguments used in deployment
 */
export const verify = async (contractAddress: string, args: any[]) => {
  console.log("Verifying contract...");
  try {
    await run("verify:verify", {
      address: contractAddress,
      constructorArguments: args,
    });
    console.log("Contract verified!");
  } catch (e: any) {
    if (e.message.toLowerCase().includes("already verified")) {
      console.log("Contract already verified!");
    } else {
      console.log("Verification error:", e);
    }
  }
}; 