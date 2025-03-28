import "@nomiclabs/hardhat-ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";

describe("ValidatorFactory", () => {
    let validatorFactory: Contract;
    let creditSystem: Contract;
    let token: Contract;
    let nonWhitelistedToken: Contract;
    let owner: SignerWithAddress;
    let user: SignerWithAddress;

    beforeEach(async () => {
        [owner, user] = await ethers.getSigners();

        // Deploy tokens
        const Token = await ethers.getContractFactory("MockERC20");
        token = await Token.deploy("Test Token", "TEST", 18);
        await token.deployed();

        nonWhitelistedToken = await Token.deploy("Non-Whitelisted Token", "NWTEST", 18);
        await nonWhitelistedToken.deployed();

        // Deploy mock price oracle
        const MockPriceOracle = await ethers.getContractFactory("MockPriceOracle");
        const priceOracle = await MockPriceOracle.deploy();
        await priceOracle.deployed();

        // Deploy credit system
        const CreditSystem = await ethers.getContractFactory("CreditSystem");
        creditSystem = await CreditSystem.deploy(
            token.address, // USDC
            token.address, // USDT (using same token for simplicity)
            priceOracle.address,
            ethers.constants.AddressZero // Initial validator factory is zero
        );
        await creditSystem.deployed();

        // Deploy validator factory with token whitelisted
        const ValidatorFactory = await ethers.getContractFactory("ValidatorFactory");
        validatorFactory = await ValidatorFactory.deploy(
            creditSystem.address,
            ethers.utils.parseEther("1000"), // Min stake
            1000, // Max fee percentage (10%)
            token.address // Default whitelisted token
        );
        await validatorFactory.deployed();

        // Update credit system with validator factory
        await creditSystem.setValidatorFactory(validatorFactory.address);

        // Fund user with tokens
        await token.connect(owner).transfer(user.address, ethers.utils.parseEther("2000"));
        await nonWhitelistedToken.connect(owner).transfer(user.address, ethers.utils.parseEther("2000"));
    });

    describe("Token Whitelist", () => {
        it("should allow creating validator with whitelisted token", async () => {
            await token.connect(user).approve(validatorFactory.address, ethers.utils.parseEther("2000"));
            
            await expect(
                validatorFactory.connect(user).createValidator(500, token.address)
            ).to.not.be.reverted;
        });

        it("should not allow creating validator with non-whitelisted token", async () => {
            await nonWhitelistedToken.connect(user).approve(validatorFactory.address, ethers.utils.parseEther("2000"));
            
            await expect(
                validatorFactory.connect(user).createValidator(500, nonWhitelistedToken.address)
            ).to.be.revertedWithCustomError(validatorFactory, "TokenNotWhitelisted");
        });

        it("should allow admin to whitelist a token", async () => {
            await expect(
                validatorFactory.connect(owner).setTokenWhitelist(nonWhitelistedToken.address, true)
            ).to.emit(validatorFactory, "TokenWhitelisted")
             .withArgs(nonWhitelistedToken.address, true);

            // Now should be able to create validator with previously non-whitelisted token
            await nonWhitelistedToken.connect(user).approve(validatorFactory.address, ethers.utils.parseEther("2000"));
            await expect(
                validatorFactory.connect(user).createValidator(500, nonWhitelistedToken.address)
            ).to.not.be.reverted;
        });

        it("should allow admin to remove a token from whitelist", async () => {
            // First remove token from whitelist
            await validatorFactory.connect(owner).setTokenWhitelist(token.address, false);

            // Now should not be able to create validator with that token
            await token.connect(user).approve(validatorFactory.address, ethers.utils.parseEther("2000"));
            await expect(
                validatorFactory.connect(user).createValidator(500, token.address)
            ).to.be.revertedWithCustomError(validatorFactory, "TokenNotWhitelisted");
        });

        it("should not allow non-admin to modify whitelist", async () => {
            await expect(
                validatorFactory.connect(user).setTokenWhitelist(nonWhitelistedToken.address, true)
            ).to.be.reverted;
        });
    });
}); 