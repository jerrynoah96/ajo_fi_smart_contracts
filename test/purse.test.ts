import "@nomiclabs/hardhat-ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";

// Define the roles directly to avoid import issues
const ADMIN_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ADMIN_ROLE"));

describe("PurseContract", () => {
    let purse: Contract;
    let token: Contract;
    let creditSystem: Contract;
    let validatorFactory: Contract;
    let validator: Contract;
    let owner: SignerWithAddress;
    let admin: SignerWithAddress;
    let member1: SignerWithAddress;
    let member2: SignerWithAddress;
    let member3: SignerWithAddress;
    let validatorOwner: SignerWithAddress;
    let tokenRegistry: Contract;

    const CONTRIBUTION_AMOUNT = ethers.utils.parseEther("100");
    const MAX_DELAY_TIME = 86400; // 1 day in seconds

    // Helper function to fund members with tokens and approve spending
    async function fundMembersAndApprove(members: SignerWithAddress[], amount: any) {
        for (const member of members) {
            await token.mint(member.address, amount.mul(20));
            await creditSystem.connect(owner).assignCredits(member.address, amount.mul(10));
            await token.connect(member).approve(purse.address, amount.mul(10));
        }
    }

    // Helper function to validate members with the validator
    async function validateMembers(members: SignerWithAddress[], amount: any) {
        for (const member of members) {
            await validator.connect(validatorOwner).validateUser(member.address, amount);
            await creditSystem.setUserValidator(member.address, validator.address);
        }
    }

    beforeEach(async () => {
        [owner, admin, member1, member2, member3, validatorOwner] = await ethers.getSigners();

        // Deploy mock token
        const Token = await ethers.getContractFactory("MockERC20");
        token = await Token.deploy("Test Token", "TEST", 18);
        await token.deployed();

        // Mint more tokens to owner to distribute
        await token.mint(owner.address, ethers.utils.parseEther("50000"));

        // Deploy token registry
        const TokenRegistryFactory = await ethers.getContractFactory("TokenRegistry");
        tokenRegistry = await TokenRegistryFactory.deploy();
        await tokenRegistry.deployed();

        // Whitelist token in registry
        await tokenRegistry.connect(owner).setTokenWhitelist(token.address, true);

        // Deploy credit system with null validator factory first
        const CreditSystemFactory = await ethers.getContractFactory("CreditSystem");
        creditSystem = await CreditSystemFactory.deploy(
            ethers.constants.AddressZero, // Temporary null address
            tokenRegistry.address
        );
        await creditSystem.deployed();

        // Ensure owner has admin role
        await creditSystem.grantRole(ADMIN_ROLE, owner.address);

        // Deploy validator factory with token whitelisted
        const ValidatorFactory = await ethers.getContractFactory("ValidatorFactory");
        validatorFactory = await ValidatorFactory.deploy(
            creditSystem.address,
            ethers.utils.parseEther("1000"), // Min stake
            1000, // Max fee percentage (10%)
            tokenRegistry.address // Token registry address
        );
        await validatorFactory.deployed();

        // Setup authorizations
        await creditSystem.connect(owner).authorizeFactory(validatorFactory.address, true);
        await creditSystem.connect(owner).authorizeFactory(owner.address, false);

        // Create validator
        await token.connect(owner).transfer(validatorOwner.address, ethers.utils.parseEther("5000"));
        await token.connect(validatorOwner).approve(validatorFactory.address, ethers.utils.parseEther("2000"));
        
        await validatorFactory.connect(validatorOwner).createValidator(
            50, // 0.5% fee
            token.address,
            ethers.utils.parseEther("1000") // Stake amount
        );

        // Get validator contract address
        const validatorAddress = await validatorFactory.validatorContracts(validatorOwner.address);
        validator = await ethers.getContractAt("Validator", validatorAddress);

        // Authorize the validator contract in the credit system
        await creditSystem.connect(owner).authorizeFactory(validatorAddress, false);

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
        await fundMembersAndApprove([admin, member1, member2, member3], CONTRIBUTION_AMOUNT);

        // Assign credits to validator owner
        await creditSystem.connect(owner).assignCredits(validatorOwner.address, ethers.utils.parseEther("1000"));

        // Fund validator with enough tokens for penalties
        await token.connect(owner).transfer(validator.address, CONTRIBUTION_AMOUNT.mul(20));
        
        // Setup approvals
        await token.connect(validatorOwner).approve(purse.address, CONTRIBUTION_AMOUNT.mul(20));
        await token.connect(validatorOwner).approve(creditSystem.address, CONTRIBUTION_AMOUNT.mul(20));

        // Setup members with validators
        await validateMembers([member1, member2], ethers.utils.parseEther("100"));
    });

    describe("Joining Purse", () => {
        it("should allow members to join with valid validator", async () => {
            await purse.connect(member1).joinPurse(2, validator.address);
            
            const memberInfo = await purse.getMemberInfo(member1.address);
            expect(memberInfo.hasJoined).to.be.true;
            expect(memberInfo.position).to.equal(2);
        });

        it("should reduce user credits when joining purse", async () => {
            // Check initial credits - no need to validate again
            const initialCredits = await creditSystem.userCredits(member1.address);
            
            // Join purse
            await purse.connect(member1).joinPurse(2, validator.address);
            
            // Check final credits
            const finalCredits = await creditSystem.userCredits(member1.address);
            
            // Should deduct requiredCredits (contributionAmount * (maxMembers-1))
            const purseData = await purse.purse();
            expect(initialCredits.sub(finalCredits)).to.equal(purseData.requiredCredits);
        });
    });

    describe("Default Handling", () => {
        beforeEach(async () => {
            // Fund admin with tokens for contributions
            await token.mint(admin.address, CONTRIBUTION_AMOUNT.mul(20));
            
            // Admin is already in position 1 from purse constructor
            // Continue with other setup that doesn't require pausing
            for (const member of [member1, member2]) {
                // Join purse
                await purse.connect(member).joinPurse(member === member1 ? 2 : 3, validator.address);
            }

            // Fund validator with enough tokens and approve spending
            await token.connect(owner).transfer(validator.address, CONTRIBUTION_AMOUNT.mul(20));
            await token.mint(validator.address, CONTRIBUTION_AMOUNT.mul(3));
            await token.connect(validatorOwner).approve(purse.address, CONTRIBUTION_AMOUNT.mul(20));
            await token.connect(validatorOwner).approve(creditSystem.address, CONTRIBUTION_AMOUNT.mul(20));

            // Approve token spending for contributions
            await token.connect(admin).approve(purse.address, CONTRIBUTION_AMOUNT.mul(10));
            await token.connect(member1).approve(purse.address, CONTRIBUTION_AMOUNT.mul(10));
            await token.connect(member2).approve(purse.address, CONTRIBUTION_AMOUNT.mul(10));
        });

        it("should not allow starting resolution before max delay time", async () => {
            await expect(
                purse.connect(admin).startResolveRound()
            ).to.be.revertedWithCustomError(purse, "DelayTimeNotExceeded");
        });


        it("should allow any user to start resolution after delay time", async () => {
            // Make contributions except for member2
            await purse.connect(admin).contribute();
            await purse.connect(member1).contribute();
            // member2 doesn't contribute - will be processed as defaulter

            // Log who has contributed
            for (const m of [admin, member1, member2]) {
                const info = await purse.getMemberInfo(m.address);
            }
           
            // Get recipient's initial balance
            const currentRoundInfo = await purse.getCurrentRound();
            const recipientAddress = currentRoundInfo.currentRecipient; 
            const initialRecipientBalance = await token.balanceOf(recipientAddress);
         

            // Advance time past max delay
            await ethers.provider.send("evm_increaseTime", [MAX_DELAY_TIME + 1]);
            await ethers.provider.send("evm_mine", []);

            // Listen for defaulter events
            const provider = ethers.provider;
            const filter = purse.filters.DefaulterProcessed();
            const startBlock = await provider.getBlockNumber();

            // Start resolution should process all defaulters
            await purse.connect(member1).startResolveRound();

            // Check which defaulters were processed
            const events = await purse.queryFilter(filter, startBlock);
          
            const finalRecipientBalance = await token.balanceOf(recipientAddress);
          
           
            // Verify recipient received the tokens
            expect(finalRecipientBalance.sub(initialRecipientBalance)).to.equal(CONTRIBUTION_AMOUNT.mul(3));
            
            // Verify round was completed
            const currentRound = await purse.getCurrentRound();
            expect(currentRound.round).to.equal(2);

            // Verify the resolution was completed
            const resolutionProgress = await purse.getResolutionProgress();
            expect(resolutionProgress.isProcessing).to.be.false;
        });
    });
});
