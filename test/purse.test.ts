import "@nomiclabs/hardhat-ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { Roles } from "../contracts/access/Roles";

describe("PurseContract", () => {
    let purse: Contract;
    let token: Contract;
    let creditSystem: Contract;
    let validatorFactory: Contract;
    let validator: Contract;
    let priceOracle: Contract;
    let owner: SignerWithAddress;
    let admin: SignerWithAddress;
    let member1: SignerWithAddress;
    let member2: SignerWithAddress;
    let member3: SignerWithAddress;
    let validatorOwner: SignerWithAddress;

    const CONTRIBUTION_AMOUNT = ethers.utils.parseEther("100");
    const MAX_MEMBERS = 3;
    const ROUND_INTERVAL = 60 * 60 * 24; // 1 day
    const MAX_DELAY_TIME = 60 * 60 * 24 * 2; // 2 days

    beforeEach(async () => {
        [owner, admin, member1, member2, member3, validatorOwner] = await ethers.getSigners();

        // Deploy token
        const TokenFactory = await ethers.getContractFactory("Token");
        token = await TokenFactory.deploy();

        // Deploy price oracle
        const MockPriceOracleFactory = await ethers.getContractFactory("MockPriceOracle");
        priceOracle = await MockPriceOracleFactory.deploy();

        // Deploy credit system
        const CreditSystemFactory = await ethers.getContractFactory("CreditSystem");
        creditSystem = await CreditSystemFactory.deploy(
            token.address,
            token.address,
            priceOracle.address,
            ethers.constants.AddressZero // Temporary zero address
        );

        // Deploy validator factory
        const ValidatorFactoryFactory = await ethers.getContractFactory("ValidatorFactory");
        validatorFactory = await ValidatorFactoryFactory.deploy(
            creditSystem.address,
            ethers.utils.parseUnits("1000", "ether"),
            1000 // 10% max fee
        );

        // Update credit system's validator factory
        await creditSystem.connect(owner).setValidatorFactory(validatorFactory.address);

        // Setup validator
        await token.transfer(validatorOwner.address, ethers.utils.parseUnits("2000", "ether"));
        await token.connect(validatorOwner).approve(validatorFactory.address, ethers.utils.parseUnits("1000", "ether"));
        await validatorFactory.connect(validatorOwner).createValidator(500, token.address);

        const validatorAddress = await validatorFactory.getValidatorContract(validatorOwner.address);
        validator = await ethers.getContractAt("Validator", validatorAddress);

        // Deploy purse
        const PurseFactory = await ethers.getContractFactory("PurseContract");
        purse = await PurseFactory.deploy(
            admin.address,
            CONTRIBUTION_AMOUNT,
            MAX_MEMBERS,
            ROUND_INTERVAL,
            token.address,
            1, // admin position
            creditSystem.address,
            validatorFactory.address,
            MAX_DELAY_TIME
        );

        // Setup credit system roles and permissions
        await creditSystem.grantRole(ethers.constants.HashZero, owner.address);
        await creditSystem.connect(owner).authorizeFactory(owner.address);
        await creditSystem.connect(owner).registerPurse(purse.address);

        // Fund members with tokens and credits
        for (const member of [member1, member2, member3]) {
            await token.transfer(member.address, CONTRIBUTION_AMOUNT.mul(MAX_MEMBERS));
            await token.connect(member).approve(purse.address, CONTRIBUTION_AMOUNT.mul(MAX_MEMBERS));
            await creditSystem.connect(owner).assignCredits(member.address, CONTRIBUTION_AMOUNT.mul(MAX_MEMBERS));
        }
    });

    describe("Joining Purse", () => {
        beforeEach(async () => {
            // Validate members with validator
            for (const member of [member1, member2]) {
                await validator.connect(validatorOwner).validateUser(member.address);
            }
        });

        it("should allow members to join with valid validator", async () => {
            await purse.connect(member1).joinPurse(2, validatorOwner.address);
            
            const memberInfo = await purse.getMemberInfo(member1.address);
            expect(memberInfo.hasJoined).to.be.true;
            expect(memberInfo.position).to.equal(2);
        });

        it("should not allow joining without validator validation", async () => {
            await expect(
                purse.connect(member3).joinPurse(3, validatorOwner.address)
            ).to.be.revertedWithCustomError(purse, "UserNotValidatedByValidator");
        });
    });

    describe("Default Handling", () => {
        beforeEach(async () => {
            // Setup members with validators and link them in credit system
            for (const member of [member1, member2]) {
                // Validate users with validator
                await validator.connect(validatorOwner).validateUser(member.address);
                
                // Link users to validator in credit system
                await creditSystem.connect(owner).setUserValidator(member.address, validatorOwner.address);
                
                // Join purse
                await purse.connect(member).joinPurse(member === member1 ? 2 : 3, validatorOwner.address);
            }

            // Fund admin and members with tokens
            await token.connect(owner).transfer(admin.address, CONTRIBUTION_AMOUNT.mul(10));
            await token.connect(owner).transfer(member1.address, CONTRIBUTION_AMOUNT.mul(10));
            await token.connect(owner).transfer(member2.address, CONTRIBUTION_AMOUNT.mul(10));

            // Fund validator contract with tokens for penalties
            await token.connect(owner).transfer(validator.address, CONTRIBUTION_AMOUNT.mul(10));

            // Approve token spending
            await token.connect(admin).approve(purse.address, CONTRIBUTION_AMOUNT.mul(10));
            await token.connect(member1).approve(purse.address, CONTRIBUTION_AMOUNT.mul(10));
            await token.connect(member2).approve(purse.address, CONTRIBUTION_AMOUNT.mul(10));
        });

        it("should not allow starting resolution before max delay time", async () => {
            await expect(
                purse.connect(admin).startResolveRound()
            ).to.be.revertedWithCustomError(purse, "DelayTimeNotExceeded");
        });

        it("should not allow non-admin to process defaulters", async () => {
            await ethers.provider.send("evm_increaseTime", [MAX_DELAY_TIME + 1]);
            await ethers.provider.send("evm_mine", []);

            await purse.connect(admin).startResolveRound();

            await expect(
                purse.connect(member1).processDefaultersBatch()
            ).to.be.revertedWithCustomError(purse, "OnlyAdminCanCall");
        });

        it("should not allow starting resolution when already processing", async () => {
            await ethers.provider.send("evm_increaseTime", [MAX_DELAY_TIME + 1]);
            await ethers.provider.send("evm_mine", []);

            await purse.connect(admin).startResolveRound();

            await expect(
                purse.connect(admin).startResolveRound()
            ).to.be.revertedWithCustomError(purse, "AlreadyProcessingDefaulters");
        });

        it("should revert when finalizing resolution that hasn't started", async () => {
            // We need to call finalizeRoundResolution through another function that calls it
            // since it's internal. One way is to process all defaulters which triggers finalization
            await expect(
                purse.connect(admin).processDefaultersBatch()
            ).to.be.revertedWithCustomError(purse, "ResolutionNotStarted");
        });
    });
});
