import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

// Define roles directly
const ADMIN_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ADMIN_ROLE"));

describe("CreditSystem", () => {
  let creditSystem: Contract;
  let tokenRegistry: Contract;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;
  let factory: SignerWithAddress;
  let token: Contract;
  let validatorFactory: Contract;
  let validator: Contract;
  let validatorOwner: SignerWithAddress;
  let otherUser: SignerWithAddress;

  // Helper function for setting up mock purse and validator
  async function setupMockPurseAndValidator() {
    await creditSystem.connect(owner).authorizeFactory(owner.address, false);
    await creditSystem.connect(owner).registerPurse(owner.address);
  }

  // Helper function for creating a validator if needed
  async function ensureValidatorCreated() {
    let validatorContractAddress = await validatorFactory.getValidatorContract(validatorOwner.address);
    
    // Only create a new validator if one doesn't exist
    if (validatorContractAddress === ethers.constants.AddressZero) {
      await token.connect(validatorOwner).approve(validatorFactory.address, ethers.utils.parseEther("2000"));
      await validatorFactory.connect(validatorOwner).createValidator(
        50, // fee percentage (0.5%) - maximum allowed
        token.address, // staked token
        ethers.utils.parseEther("1000") // initial stake
      );
      validatorContractAddress = await validatorFactory.getValidatorContract(validatorOwner.address);
    }
    
    return await ethers.getContractAt("Validator", validatorContractAddress);
  }

  beforeEach(async () => {
    [owner, user, factory, otherUser, validatorOwner] = await ethers.getSigners();

    // Deploy mock token
    const TokenFactory = await ethers.getContractFactory("MockERC20");
    token = await TokenFactory.deploy("Test Token", "TEST", 18);
    await token.deployed();

    // Deploy TokenRegistry
    const TokenRegistryFactory = await ethers.getContractFactory("TokenRegistry");
    tokenRegistry = await TokenRegistryFactory.deploy();
    await tokenRegistry.deployed();

    // Whitelist token in registry
    await tokenRegistry.connect(owner).setTokenWhitelist(token.address, true);

    // Deploy validator factory first
    const ValidatorFactoryFactory = await ethers.getContractFactory("ValidatorFactory");
    validatorFactory = await ValidatorFactoryFactory.deploy(
      ethers.constants.AddressZero, // Will be updated after credit system
      ethers.utils.parseUnits("1000", "ether"), // min stake
      50, 
      tokenRegistry.address
    );
    await validatorFactory.deployed();
    
    // Whitelist token in validator factory
    await validatorFactory.connect(owner).setTokenWhitelist(token.address, true);

    // Deploy credit system with validator factory
    const CreditSystemFactory = await ethers.getContractFactory("CreditSystem");
    creditSystem = await CreditSystemFactory.deploy(
      validatorFactory.address,
      tokenRegistry.address
    );
    await creditSystem.deployed();

    // Update validator factory with credit system
    await validatorFactory.connect(owner).updateCreditSystem(creditSystem.address);

    // Setup credit system roles
    await creditSystem.grantRole(ethers.constants.HashZero, owner.address);
    await creditSystem.grantRole(ADMIN_ROLE, owner.address);

    // Authorize the validator factory in the credit system
    await creditSystem.connect(owner).authorizeFactory(validatorFactory.address, true);

    // Setup initial token balances
    await token.mint(user.address, ethers.utils.parseEther("1000"));
    await token.connect(user).approve(creditSystem.address, ethers.utils.parseEther("1000"));

    // Setup validator owner with tokens
    await token.mint(validatorOwner.address, ethers.utils.parseUnits("5000", "ether"));
    await token.connect(validatorOwner).approve(validatorFactory.address, ethers.utils.parseUnits("1000", "ether"));
    
    // Create validator instance
    validator = await ensureValidatorCreated();

    // Authorize the validator contract in the credit system
    await creditSystem.connect(owner).authorizeFactory(validator.address, false);
  });

  describe("Token Staking and Credits", () => {
    it("should allow staking tokens and receive credits", async () => {
      const stakeAmount = ethers.utils.parseEther("10");
      await creditSystem.connect(user).stakeToken(token.address, stakeAmount);
      
      expect(await creditSystem.userCredits(user.address)).to.equal(stakeAmount);
      const stake = await creditSystem.userTokenStakes(user.address, token.address);
      expect(stake.amount).to.equal(stakeAmount);
      expect(stake.creditsIssued).to.equal(stakeAmount);
    });

    it("should not allow staking non-whitelisted tokens", async () => {
      const NonWhitelistedToken = await ethers.getContractFactory("MockERC20");
      const nonWhitelistedToken = await NonWhitelistedToken.deploy("Non-Whitelisted", "NWT", 18);
      await nonWhitelistedToken.deployed();
      
      await nonWhitelistedToken.mint(user.address, ethers.utils.parseEther("100"));
      await nonWhitelistedToken.connect(user).approve(creditSystem.address, ethers.utils.parseEther("100"));
      
      await expect(
        creditSystem.connect(user).stakeToken(nonWhitelistedToken.address, ethers.utils.parseEther("100"))
      ).to.be.revertedWith("Token not whitelisted");
    });

    it("should allow unstaking tokens after minimum time", async () => {
      const stakeAmount = ethers.utils.parseEther("10");
      await creditSystem.connect(user).stakeToken(token.address, stakeAmount);
      
      // Fast forward time to meet minimum stake time
      await ethers.provider.send("evm_increaseTime", [86401]); // 1 day + 1 second
      await ethers.provider.send("evm_mine", []);
      
      const initialBalance = await token.balanceOf(user.address);
      await creditSystem.connect(user).unstakeToken(token.address, stakeAmount);
      
      expect(await creditSystem.userCredits(user.address)).to.equal(0);
      expect(await token.balanceOf(user.address)).to.equal(initialBalance.add(stakeAmount));
    });
  });

  describe("Factory Management", () => {
    it("should allow admin to authorize factory", async () => {
      await creditSystem.connect(owner).authorizeFactory(factory.address, false);
      expect(await creditSystem.authorizedFactories(factory.address)).to.be.true;
    });

    it("should allow authorized factory to register purse", async () => {
      await creditSystem.connect(owner).authorizeFactory(factory.address, false);
      await creditSystem.connect(factory).registerPurse(user.address);
      expect(await creditSystem.authorizedPurses(user.address)).to.be.true;
    });

    it("should allow authorized factory to assign credits", async () => {
      await creditSystem.connect(owner).authorizeFactory(factory.address, false);
      const amount = ethers.utils.parseEther("100");
      
      await creditSystem.connect(factory).assignCredits(user.address, amount);
      expect(await creditSystem.userCredits(user.address)).to.equal(amount);
    });

    it("should allow authorized factory to reduce credits", async () => {
      await creditSystem.connect(owner).authorizeFactory(factory.address, false);
      const amount = ethers.utils.parseEther("100");
      
      await creditSystem.connect(factory).assignCredits(user.address, amount);
      await creditSystem.connect(factory).reduceCredits(user.address, amount.div(2));
      expect(await creditSystem.userCredits(user.address)).to.equal(amount.div(2));
    });
  });

  describe("Admin Functions", () => {
    it("should allow admin to update token registry", async () => {
      const newTokenRegistry = await (await ethers.getContractFactory("TokenRegistry")).deploy();
      await newTokenRegistry.deployed();
      
      await expect(
        creditSystem.connect(owner).setTokenRegistry(newTokenRegistry.address)
      ).to.emit(creditSystem, "TokenRegistryUpdated");
      
      expect(await creditSystem.tokenRegistry()).to.equal(newTokenRegistry.address);
    });
  });

  describe("Default Handling", () => {
    it("should handle defaulter penalties correctly", async () => {
      // Create a fresh purse for this test to avoid any state conflicts
      await creditSystem.connect(owner).authorizeFactory(owner.address, false);
      await creditSystem.connect(owner).registerPurse(owner.address);
      
      // Setup: Give user some credits, validate them
      const defaultAmount = ethers.utils.parseUnits("10", "ether");
      // Calculate amount after fee (0.5% fee)
      const amountAfterFee = defaultAmount.mul(9950).div(10000);
      
      // Deploy validator for the defaulter
      let validatorContractAddress = await validatorFactory.getValidatorContract(validatorOwner.address);
      
      // Only create a new validator if one doesn't exist
      if (validatorContractAddress === ethers.constants.AddressZero) {
        await token.connect(validatorOwner).approve(validatorFactory.address, ethers.utils.parseEther("2000"));
        await validatorFactory.connect(validatorOwner).createValidator(
          50, // fee percentage (0.5%) - maximum allowed
          token.address, // staked token
          ethers.utils.parseEther("1000") // initial stake
        );
        validatorContractAddress = await validatorFactory.getValidatorContract(validatorOwner.address);
      }
      
      const validator = await ethers.getContractAt("Validator", validatorContractAddress);
      
      // Authorize validator in credit system
      await creditSystem.connect(owner).authorizeFactory(validatorFactory.address, true);
      
      // Add credits to validator owner and validate user
      await creditSystem.connect(owner).assignCredits(validatorOwner.address, defaultAmount.mul(2));
      await validator.connect(validatorOwner).validateUser(user.address, defaultAmount);
      
      // Clean up validation status check
      expect(await validator.isUserValidated(user.address)).to.be.true;

      await creditSystem.connect(owner).authorizeFactory(owner.address, false);
      await creditSystem.connect(owner).registerPurse(owner.address);
      
      // Commit credits to purse - avoid using the user as their own purse to prevent confusion
      await creditSystem.connect(owner).commitCreditsToPurse(
        user.address,
        owner.address, // Use owner address as the purse
        amountAfterFee,  // Use amount after validator fee
        validator.address
      );
      
      // Process default
      await creditSystem.connect(owner).handleUserDefault(
        user.address,
        owner.address, // Use owner address as the purse
        amountAfterFee,  // Use amount after validator fee
        validator.address
      );
      
      // Verify defaulter history updated
      const defaultHistory = await creditSystem.getValidatorDefaulterHistory(
        validator.address,
        user.address
      );
      expect(defaultHistory).to.equal(amountAfterFee);
    });

    it("should not reduce validator stake when defaulter is recipient", async () => {
        const defaultAmount = ethers.utils.parseUnits("10", "ether");
       
        // Authorize validator in credit system
      await creditSystem.connect(owner).authorizeFactory(validatorFactory.address, true);
      await creditSystem.connect(owner).authorizeFactory(owner.address, false);
      await creditSystem.connect(owner).assignCredits(user.address, defaultAmount.mul(2));

      
        
        // First authorize owner as a factory (required to register purses)
        const mockPurse = owner;
        await creditSystem.authorizeFactory(owner.address, false);
        await creditSystem.registerPurse(mockPurse.address);
        await validator.connect(validatorOwner).validateUser(user.address, defaultAmount);
     
        
        // Get initial validator credits
        const initialValidatorCredits = await creditSystem.userCredits(validatorOwner.address);
        await creditSystem.connect(owner).authorizeFactory(validatorFactory.address, true);

        // Commit credits to purse first
        await creditSystem.connect(owner).commitCreditsToPurse(
            user.address,
            mockPurse.address,
            defaultAmount,
            validator.address
        );

        // // Test with same defaulter and recipient
        await creditSystem.connect(mockPurse).handleUserDefault(
            user.address,
            mockPurse.address,
            defaultAmount,
            user.address // Same as defaulter
        );

        // // The validator credits should remain unchanged when defaulter is the recipient
        const finalValidatorCredits = await creditSystem.userCredits(validatorOwner.address);
        expect(finalValidatorCredits).to.equal(initialValidatorCredits);
    });

    it("should emit correct events", async () => {
      // Setup: create purse, validator, etc.
      await creditSystem.connect(owner).authorizeFactory(owner.address, false);
      await creditSystem.connect(owner).registerPurse(owner.address);
      
      const defaultAmount = ethers.utils.parseUnits("1", "ether");
      
      // Calculate amount after fee (0.5% fee)
      const amountAfterFee = defaultAmount.mul(9950).div(10000);
      
      // Get validator contract
      const validatorContractAddress = await validatorFactory.getValidatorContract(validatorOwner.address);
      const validator = await ethers.getContractAt("Validator", validatorContractAddress);
      
      // Authorize validator in credit system
      await creditSystem.connect(owner).authorizeFactory(validatorFactory.address, true);
      
      // Add credits to validator owner and validate user
      await creditSystem.connect(owner).assignCredits(validatorOwner.address, defaultAmount.mul(2));
      await validator.connect(validatorOwner).validateUser(user.address, defaultAmount);
      
      // Commit credits to purse - use amountAfterFee
      await expect(
        creditSystem.connect(owner).commitCreditsToPurse(
          user.address,
          owner.address, // purse
          amountAfterFee,
          validator.address
        )
      ).to.emit(creditSystem, "CreditsCommitted")
       .withArgs(user.address, owner.address, amountAfterFee, validator.address);
      
      // Process default and check for event
      await expect(
        creditSystem.connect(owner).handleUserDefault(
          user.address,
          owner.address, // purse
          amountAfterFee, // Use the same amount we committed
          otherUser.address // recipient
        )
      ).to.emit(creditSystem, "DefaulterPenaltyApplied")
       .withArgs(user.address, validator.address, amountAfterFee);
    });
  });

  describe("Purse Credit Management", () => {
    it("should allow committing credits to a purse", async () => {
      // Give user some credits
      const creditAmount = ethers.utils.parseEther("100");
      // Authorize owner as a factory before assigning credits
      await creditSystem.connect(owner).authorizeFactory(owner.address, false);
      await creditSystem.connect(owner).assignCredits(user.address, creditAmount);
      
      // Register the purse
      await creditSystem.connect(owner).registerPurse(owner.address);
      
      // Commit credits
      await creditSystem.connect(owner).commitCreditsToPurse(
        user.address,
        owner.address, // purse
        ethers.utils.parseEther("50"),
        validator.address  
      );
      
      // Check credits were deducted
      expect(await creditSystem.userCredits(user.address)).to.equal(ethers.utils.parseEther("50"));
      
      // Check purse credits
      const purseCredit = await creditSystem.getUserPurseCredit(user.address, owner.address);
      expect(purseCredit.amount).to.equal(ethers.utils.parseEther("50"));
      expect(purseCredit.validator).to.equal(validator.address);
      expect(purseCredit.active).to.be.true;
    });
    
    it("should handle defaults correctly with validator", async () => {
      // Setup
      const creditAmount = ethers.utils.parseEther("100");
      // Authorize owner as a factory before assigning credits
      await creditSystem.connect(owner).authorizeFactory(owner.address, false);
      await creditSystem.connect(owner).assignCredits(user.address, creditAmount);
      await creditSystem.connect(owner).registerPurse(owner.address);
      
      // Stake tokens for validator if needed
      await token.connect(validatorOwner).approve(validator.address, ethers.utils.parseEther("50"));
      await validator.connect(validatorOwner).addStake(ethers.utils.parseEther("50"));
      
      // Commit credits with validator
      await creditSystem.connect(owner).commitCreditsToPurse(
        user.address,
        owner.address, // purse
        ethers.utils.parseEther("50"),
        validator.address
      );
      
      // Get initial validator credits
      const initialValidatorCredits = await creditSystem.userCredits(validatorOwner.address);
      
      // Process default
      await creditSystem.connect(owner).handleUserDefault(
        user.address,
        owner.address, // purse
        ethers.utils.parseEther("25"),
        otherUser.address // recipient
      );
      
      // Check validator defaulter history
      const defaultHistory = await creditSystem.getValidatorDefaulterHistory(
        validator.address,
        user.address
      );
      expect(defaultHistory).to.equal(ethers.utils.parseEther("25"));
      
      
      // Check recipient received tokens
      expect(await token.balanceOf(otherUser.address)).to.equal(ethers.utils.parseEther("25"));
    });
    
    it("should handle defaults correctly without validator", async () => {
      // Setup
      const creditAmount = ethers.utils.parseEther("100");
      // Authorize owner as a factory before assigning credits
      await creditSystem.connect(owner).authorizeFactory(owner.address, false);
      await creditSystem.connect(owner).assignCredits(user.address, creditAmount);
      await creditSystem.connect(owner).registerPurse(owner.address);
      
      // Get initial user credits
      const initialUserCredits = await creditSystem.userCredits(user.address);
      
      // Commit credits without validator
      await creditSystem.connect(owner).commitCreditsToPurse(
        user.address,
        owner.address, // purse
        ethers.utils.parseEther("50"),
        ethers.constants.AddressZero // no validator
      );
      
      // Release credits
      await creditSystem.connect(owner).releasePurseCredits(
        user.address,
        owner.address // purse
      );
      
      // Check credits were returned to user - should be back to the initial amount
      const finalUserCredits = await creditSystem.userCredits(user.address);
      expect(finalUserCredits).to.equal(initialUserCredits);
    });
    
    it("should release credits properly with validator", async () => {
      // Setup
      const creditAmount = ethers.utils.parseEther("100");
      // Authorize owner as a factory before assigning credits
      await creditSystem.connect(owner).authorizeFactory(owner.address, false);
      await creditSystem.connect(owner).assignCredits(user.address, creditAmount);
      await creditSystem.connect(owner).registerPurse(owner.address);
      
      // Add credits to validator owner and validate user first
      await validator.connect(validatorOwner).validateUser(user.address, creditAmount);
      
      // Get initial validator credits before commit
      const initialValidatorCredits = await creditSystem.userCredits(validator.address);
      
      // Commit credits with validator
      await creditSystem.connect(owner).commitCreditsToPurse(
        user.address,
        owner.address, // purse
        ethers.utils.parseEther("50"),
        validator.address // validator
      );
      
      // Release credits
      await creditSystem.connect(owner).releasePurseCredits(
        user.address,
        owner.address // purse
      );
      
      // Check credits were returned to validator (should have increased by 50 ETH)
      const finalValidatorCredits = await creditSystem.userCredits(validator.address);
      expect(finalValidatorCredits.sub(initialValidatorCredits)).to.equal(ethers.utils.parseEther("50"));
      
      // Check purse credit no longer active
      const purseCredit = await creditSystem.getUserPurseCredit(user.address, owner.address);
      expect(purseCredit.active).to.be.false;
    });
    
    it("should release credits properly without validator", async () => {
      // Setup
      const creditAmount = ethers.utils.parseEther("100");
      // Authorize owner as a factory before assigning credits
      await creditSystem.connect(owner).authorizeFactory(owner.address, false);
      await creditSystem.connect(owner).assignCredits(user.address, creditAmount);
      await creditSystem.connect(owner).registerPurse(owner.address);
      
      // Get initial user credits
      const initialUserCredits = await creditSystem.userCredits(user.address);
      
      // Commit credits without validator
      await creditSystem.connect(owner).commitCreditsToPurse(
        user.address,
        owner.address, // purse
        ethers.utils.parseEther("50"),
        ethers.constants.AddressZero // no validator
      );
      
      // Release credits
      await creditSystem.connect(owner).releasePurseCredits(
        user.address,
        owner.address // purse
      );
      
      // Check credits were returned to user - should be back to the initial amount
      const finalUserCredits = await creditSystem.userCredits(user.address);
      expect(finalUserCredits).to.equal(initialUserCredits);
    });
  });
}); 