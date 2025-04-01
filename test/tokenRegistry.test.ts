import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { Roles } from "../contracts/access/Roles";

describe("TokenRegistry", () => {
  let tokenRegistry: Contract;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;
  let token1: Contract;
  let token2: Contract;
  let token3: Contract;

  beforeEach(async () => {
    [owner, user] = await ethers.getSigners();

    // Deploy TokenRegistry
    const TokenRegistryFactory = await ethers.getContractFactory("TokenRegistry");
    tokenRegistry = await TokenRegistryFactory.deploy();
    await tokenRegistry.deployed();

    // Deploy mock tokens
    const TokenFactory = await ethers.getContractFactory("MockERC20");
    token1 = await TokenFactory.deploy("Token 1", "TK1", 18);
    token2 = await TokenFactory.deploy("Token 2", "TK2", 18);
    token3 = await TokenFactory.deploy("Token 3", "TK3", 18);
    await token1.deployed();
    await token2.deployed();
    await token3.deployed();
  });

  describe("Token Whitelisting", () => {
    it("should allow admin to whitelist a token", async () => {
      await expect(
        tokenRegistry.connect(owner).setTokenWhitelist(token1.address, true)
      ).to.emit(tokenRegistry, "TokenWhitelisted")
        .withArgs(token1.address, true);

      expect(await tokenRegistry.isTokenWhitelisted(token1.address)).to.be.true;
      
      // Check if token is in the list
      const whitelistedTokens = await tokenRegistry.getAllWhitelistedTokens();
      expect(whitelistedTokens).to.include(token1.address);
    });

    it("should allow admin to remove a token from whitelist", async () => {
      // First whitelist the token
      await tokenRegistry.connect(owner).setTokenWhitelist(token1.address, true);
      expect(await tokenRegistry.isTokenWhitelisted(token1.address)).to.be.true;
      
      // Then remove it from whitelist
      await expect(
        tokenRegistry.connect(owner).setTokenWhitelist(token1.address, false)
      ).to.emit(tokenRegistry, "TokenWhitelisted")
        .withArgs(token1.address, false);

      expect(await tokenRegistry.isTokenWhitelisted(token1.address)).to.be.false;
      
      // Check if token is not in the active list
      const whitelistedTokens = await tokenRegistry.getAllWhitelistedTokens();
      expect(whitelistedTokens).to.not.include(token1.address);
    });
    
    it("should not allow non-admin to whitelist tokens", async () => {
      await expect(
        tokenRegistry.connect(user).setTokenWhitelist(token1.address, true)
      ).to.be.reverted;
    });
    
    it("should not allow zero address to be whitelisted", async () => {
      await expect(
        tokenRegistry.connect(owner).setTokenWhitelist(ethers.constants.AddressZero, true)
      ).to.be.revertedWith("Cannot whitelist zero address");
    });
  });

  describe("Batch Operations", () => {
    it("should allow batch whitelisting of tokens", async () => {
      const tokens = [token1.address, token2.address, token3.address];
      const statuses = [true, true, true];
      
      await tokenRegistry.connect(owner).batchSetTokenWhitelist(tokens, statuses);
      
      for (const token of tokens) {
        expect(await tokenRegistry.isTokenWhitelisted(token)).to.be.true;
      }
      
      const whitelistedTokens = await tokenRegistry.getAllWhitelistedTokens();
      expect(whitelistedTokens.length).to.equal(3);
      expect(whitelistedTokens).to.include.members(tokens);
    });
    
    it("should validate input arrays have matching lengths", async () => {
      const tokens = [token1.address, token2.address, token3.address];
      const statuses = [true, true]; // One less than tokens
      
      await expect(
        tokenRegistry.connect(owner).batchSetTokenWhitelist(tokens, statuses)
      ).to.be.revertedWith("Array lengths must match");
    });
  });

  describe("Listing Functions", () => {
    beforeEach(async () => {
      // Setup some whitelisted tokens
      await tokenRegistry.connect(owner).setTokenWhitelist(token1.address, true);
      await tokenRegistry.connect(owner).setTokenWhitelist(token2.address, true);
      await tokenRegistry.connect(owner).setTokenWhitelist(token3.address, true);
      
      // Remove one from whitelist
      await tokenRegistry.connect(owner).setTokenWhitelist(token2.address, false);
    });
    
    it("should return all active whitelisted tokens", async () => {
      const whitelistedTokens = await tokenRegistry.getAllWhitelistedTokens();
      
      expect(whitelistedTokens.length).to.equal(2);
      expect(whitelistedTokens).to.include(token1.address);
      expect(whitelistedTokens).to.include(token3.address);
      expect(whitelistedTokens).to.not.include(token2.address);
    });
  });
}); 