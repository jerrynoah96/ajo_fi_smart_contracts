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
    const MAX_DELAY_TIME = 86400; // 1 day in seconds

    beforeEach(async () => {
        [owner, admin, member1, member2, member3, validatorOwner] = await ethers.getSigners();

        // Deploy mock token
        const Token = await ethers.getContractFactory("MockERC20");
        token = await Token.deploy("Test Token", "TEST", 18);
        await token.deployed();

        // Deploy mock price oracle
        const MockPriceOracle = await ethers.getContractFactory("MockPriceOracle");
        priceOracle = await MockPriceOracle.deploy();
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

        // Create validator
        await token.connect(owner).transfer(validatorOwner.address, ethers.utils.parseEther("2000"));
        await token.connect(validatorOwner).approve(validatorFactory.address, ethers.utils.parseEther("2000"));
        
        await validatorFactory.connect(validatorOwner).createValidator(
            500, // 5% fee
            token.address
        );

        // Get validator contract address
        const validatorAddress = await validatorFactory.validatorContracts(validatorOwner.address);
        validator = await ethers.getContractAt("Validator", validatorAddress);

        // Deploy purse contract
        const PurseContract = await ethers.getContractFactory("PurseContract");
        purse = await PurseContract.deploy(
            admin.address,
            CONTRIBUTION_AMOUNT,
            3, // max members
            2592000, // 30 days in seconds
            token.address,
            1, // admin position
            creditSystem.address,
            validatorFactory.address,
            MAX_DELAY_TIME
        );
        await purse.deployed();

        // Register purse with credit system
        await creditSystem.connect(owner).registerPurse(purse.address);

        // Fund members with tokens and credits
        for (const member of [member1, member2, member3]) {
            await token.connect(owner).transfer(member.address, CONTRIBUTION_AMOUNT.mul(10));
            await creditSystem.connect(owner).assignCredits(member.address, CONTRIBUTION_AMOUNT.mul(10));
        }

        // Assign credits to validator owner
        await creditSystem.connect(owner).assignCredits(validatorOwner.address, ethers.utils.parseEther("1000"));
    });

    describe("Joining Purse", () => {
        beforeEach(async () => {
            // Validate members with validator
            for (const member of [member1, member2]) {
                await validator.connect(validatorOwner).validateUser(member.address, ethers.utils.parseEther("100"));
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
            ).to.be.revertedWith("User not validated by validator");
        });

        it("should reduce user credits when joining purse", async () => {
            // Check initial credits - no need to validate again
            const initialCredits = await creditSystem.userCredits(member1.address);
            
            // Join purse
            await purse.connect(member1).joinPurse(2, validatorOwner.address);
            
            // Check final credits
            const finalCredits = await creditSystem.userCredits(member1.address);
            
            // Verify credits were reduced by requiredCredits
            const purseData = await purse.purse();
            expect(initialCredits.sub(finalCredits)).to.equal(purseData.requiredCredits);
        });
    });

    describe("Default Handling", () => {
        beforeEach(async () => {
            // Setup members with validators and link them in credit system
            for (const member of [member1, member2]) {
                // Validate users with validator
                await validator.connect(validatorOwner).validateUser(member.address, ethers.utils.parseEther("100"));
                
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
            ).to.be.revertedWith("Delay time not exceeded");
        });

        it("should not allow non-admin to process defaulters", async () => {
            await ethers.provider.send("evm_increaseTime", [MAX_DELAY_TIME + 1]);
            await ethers.provider.send("evm_mine", []);

            await purse.connect(admin).startResolveRound();

            await expect(
                purse.connect(member1).processDefaultersBatch()
            ).to.be.revertedWith("Only admin can call");
        });

        it("should allow any user to start resolution after delay time", async () => {
            // Make contributions except for member2
            await purse.connect(admin).contribute();
            await purse.connect(member1).contribute();

            // Advance time past max delay
            await ethers.provider.send("evm_increaseTime", [MAX_DELAY_TIME + 1]);
            await ethers.provider.send("evm_mine", []);

            // Non-admin member can start resolution
            await expect(
                purse.connect(member1).startResolveRound()
            ).to.emit(purse, "RoundResolutionStarted")
             .withArgs(1);
        });

        it("should process all defaulters automatically when starting resolution", async () => {
            // Make contributions except for member2
            await purse.connect(admin).contribute();
            await purse.connect(member1).contribute();

            const initialValidatorStake = (await validator.getValidatorData()).stakedAmount;

            // Advance time past max delay
            await ethers.provider.send("evm_increaseTime", [MAX_DELAY_TIME + 1]);
            await ethers.provider.send("evm_mine", []);

            // Start resolution should process all defaulters
            await purse.connect(member1).startResolveRound();

            // Verify validator stake was reduced
            const finalValidatorStake = (await validator.getValidatorData()).stakedAmount;
            expect(initialValidatorStake.sub(finalValidatorStake)).to.equal(CONTRIBUTION_AMOUNT);
            
            // Verify round was completed
            const currentRound = await purse.getCurrentRound();
            expect(currentRound.round).to.be.gt(1);
        });
    });
});
