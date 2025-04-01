import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract, BigNumber } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { Roles } from "../contracts/access/Roles";

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
      1000, // 10% max fee
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
    await creditSystem.grantRole(Roles.ADMIN_ROLE, owner.address);

    // Authorize the validator factory in the credit system
    await creditSystem.connect(owner).authorizeFactory(validatorFactory.address);

    // Setup initial token balances
    await token.mint(user.address, ethers.utils.parseEther("1000"));
    await token.connect(user).approve(creditSystem.address, ethers.utils.parseEther("1000"));

    // Setup validator
    await token.mint(validatorOwner.address, ethers.utils.parseUnits("5000", "ether"));
    await token.connect(validatorOwner).approve(validatorFactory.address, ethers.utils.parseUnits("1000", "ether"));
    await validatorFactory.connect(validatorOwner).createValidator(
      500, 
      token.address,
      ethers.utils.parseUnits("1000", "ether") // Stake amount
    );

    const validatorAddress = await validatorFactory.getValidatorContract(validatorOwner.address);
    validator = await ethers.getContractAt("Validator", validatorAddress);

    // Authorize the validator contract in the credit system
    await creditSystem.connect(owner).authorizeFactory(validatorAddress);
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

    // More tests can be added here
  });

  describe("Factory Management", () => {
    it("should allow admin to authorize factory", async () => {
      await creditSystem.connect(owner).authorizeFactory(factory.address);
      expect(await creditSystem.authorizedFactories(factory.address)).to.be.true;
    });

    it("should allow authorized factory to register purse", async () => {
      await creditSystem.connect(owner).authorizeFactory(factory.address);
      await creditSystem.connect(factory).registerPurse(user.address);
      expect(await creditSystem.authorizedPurses(user.address)).to.be.true;
    });

    it("should allow authorized factory to assign credits", async () => {
      await creditSystem.connect(owner).authorizeFactory(factory.address);
      const amount = ethers.utils.parseEther("100");
      
      await creditSystem.connect(factory).assignCredits(user.address, amount);
      expect(await creditSystem.userCredits(user.address)).to.equal(amount);
    });

    it("should allow authorized factory to reduce credits", async () => {
      await creditSystem.connect(owner).authorizeFactory(factory.address);
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
      let mockPurse = otherUser; // Using otherUser as mock purse for now
      // First authorize owner as a factory (required to register purses)
      await creditSystem.connect(owner).authorizeFactory(owner.address);
      await creditSystem.connect(owner).registerPurse(mockPurse.address);
      
      // Setup: Give user some credits, validate them
      const defaultAmount = ethers.utils.parseUnits("10", "ether");
      
      // Deploy validator for the defaulter
      let validatorContractAddress = await validatorFactory.getValidatorContract(validatorOwner.address);
      
      // Only create a new validator if one doesn't exist
      if (validatorContractAddress === ethers.constants.AddressZero) {
        await token.connect(validatorOwner).approve(validatorFactory.address, ethers.utils.parseEther("2000"));
        await validatorFactory.connect(validatorOwner).createValidator(
          500, // fee percentage (5%)
          token.address, // staked token
          ethers.utils.parseEther("1000") // initial stake
        );
        validatorContractAddress = await validatorFactory.getValidatorContract(validatorOwner.address);
      }
      
      const validator = await ethers.getContractAt("Validator", validatorContractAddress);
      
      // Authorize validator in credit system
      await creditSystem.connect(owner).authorizeFactory(validatorContractAddress);
      
      // Add credits to validator owner
      await creditSystem.connect(owner).assignCredits(validatorOwner.address, defaultAmount);
      
      // Validate the defaulter
      await validator.connect(validatorOwner).validateUser(mockPurse.address, defaultAmount);
      
      // Check validation status
      expect(await validator.isUserValidated(mockPurse.address)).to.be.true;
      
      // Commit credits to purse
      await creditSystem.connect(owner).commitCreditsToPurse(
        mockPurse.address,
        mockPurse.address,
        defaultAmount,
        validatorOwner.address
      );
      
      // Process default
      await creditSystem.connect(owner).handleUserDefault(
        mockPurse.address,
        mockPurse.address,
        defaultAmount,
        token.address,
        otherUser.address // recipient
      );
      
      // Verify defaulter history updated
      const defaultHistory = await creditSystem.getValidatorDefaulterHistory(
        validatorOwner.address,
        mockPurse.address
      );
      expect(defaultHistory).to.equal(defaultAmount);
    });

    it("should not reduce validator stake when defaulter is recipient", async () => {
        const defaultAmount = ethers.utils.parseUnits("10", "ether");
        await creditSystem.connect(owner).assignCredits(user.address, defaultAmount.mul(2));
        
        // First authorize owner as a factory (required to register purses)
        const mockPurse = owner;
        await creditSystem.authorizeFactory(owner.address);
        await creditSystem.registerPurse(mockPurse.address);

        // Validate the user with the validator
        await validator.connect(validatorOwner).validateUser(user.address, ethers.utils.parseUnits("10", "ether"));
        
        // Link user to validator in credit system
        await creditSystem.connect(owner).setUserValidator(user.address, validatorOwner.address);

        // Get initial validator credits
        const initialValidatorCredits = await creditSystem.userCredits(validatorOwner.address);

        // Test with same defaulter and recipient
        await creditSystem.connect(mockPurse).reduceCreditsForDefault(
            user.address,
            user.address, // Same as defaulter
            defaultAmount,
            validatorOwner.address
        );

        // The validator credits should remain unchanged when defaulter is the recipient
        const finalValidatorCredits = await creditSystem.userCredits(validatorOwner.address);
        expect(finalValidatorCredits).to.equal(initialValidatorCredits);
    });

    it("should emit correct events", async () => {
      // Setup: create purse, validator, etc.
      await creditSystem.connect(owner).authorizeFactory(owner.address);
      await creditSystem.connect(owner).registerPurse(owner.address);
      
      const defaultAmount = ethers.utils.parseUnits("10", "ether");
      
      // Get validator contract
      const validatorContractAddress = await validatorFactory.getValidatorContract(validatorOwner.address);
      const validator = await ethers.getContractAt("Validator", validatorContractAddress);
      
      // Authorize validator in credit system
      await creditSystem.connect(owner).authorizeFactory(validatorContractAddress);
      
      // Add credits to validator owner and validate user
      await creditSystem.connect(owner).assignCredits(validatorOwner.address, defaultAmount);
      await validator.connect(validatorOwner).validateUser(user.address, defaultAmount);
      
      // Commit credits to purse
      await expect(
        creditSystem.connect(owner).commitCreditsToPurse(
          user.address,
          owner.address, // purse
          defaultAmount,
          validatorOwner.address
        )
      ).to.emit(creditSystem, "CreditsCommitted")
       .withArgs(user.address, owner.address, defaultAmount, validatorOwner.address);
      
      // Process default and check for event
      await expect(
        creditSystem.connect(owner).handleUserDefault(
          user.address,
          owner.address, // purse
          defaultAmount,
          token.address,
          otherUser.address // recipient
        )
      ).to.emit(creditSystem, "DefaulterPenaltyApplied")
       .withArgs(user.address, validatorOwner.address, defaultAmount);
    });

    it("should fail for unauthorized purse", async () => {
      await expect(
        creditSystem.connect(user).reduceCreditsForDefault(
          user.address,
          user.address,
          100,
          validatorOwner.address
        )
      ).to.be.revertedWith("Not authorized purse");
    });

    it("should fail for invalid validator", async () => {
      const mockPurse = owner;
      await creditSystem.authorizeFactory(owner.address);
      await creditSystem.registerPurse(mockPurse.address);

      await expect(
        creditSystem.connect(mockPurse).reduceCreditsForDefault(
          user.address,
          user.address,
          100,
          ethers.constants.AddressZero
        )
      ).to.be.revertedWith("No validator found");
    });
  });

  describe("Validator Factory Management", () => {
    it("should allow admin to set validator factory", async () => {
      const ValidatorFactoryFactory = await ethers.getContractFactory("ValidatorFactory");
      const newValidatorFactory = await ValidatorFactoryFactory.deploy(
        ethers.constants.AddressZero, // Will be updated after credit system
        ethers.utils.parseUnits("1000", "ether"), // min stake
        1000, // 10% max fee
        tokenRegistry.address
      );

      await expect(
        creditSystem.connect(owner).setValidatorFactory(newValidatorFactory.address)
      ).to.emit(creditSystem, "ValidatorFactoryUpdated")
       .withArgs(validatorFactory.address, newValidatorFactory.address);

      expect(await creditSystem.validatorFactory()).to.equal(newValidatorFactory.address);
    });

    it("should not allow non-admin to set validator factory", async () => {
      await expect(
        creditSystem.connect(user).setValidatorFactory(validatorFactory.address)
      ).to.be.revertedWith(
        `AccessControl: account ${user.address.toLowerCase()} is missing role ${Roles.ADMIN_ROLE}`
      );
    });

    it("should not allow setting zero address as validator factory", async () => {
      await expect(
        creditSystem.connect(owner).setValidatorFactory(ethers.constants.AddressZero)
      ).to.be.revertedWith("Invalid validator factory");
    });

    it("should not allow setting same address as current validator factory", async () => {
      await expect(
        creditSystem.connect(owner).setValidatorFactory(await creditSystem.validatorFactory())
      ).to.be.revertedWith("Same validator factory");
    });
  });

  describe("Purse Credit Management", () => {
    it("should allow committing credits to a purse", async () => {
      // Give user some credits
      const creditAmount = ethers.utils.parseEther("100");
      await creditSystem.connect(owner).assignCredits(user.address, creditAmount);
      
      // Authorize owner as a factory before registering the purse
      await creditSystem.connect(owner).authorizeFactory(owner.address);
      // Authorize owner as purse
      await creditSystem.connect(owner).registerPurse(owner.address);
      
      // Commit credits
      await creditSystem.connect(owner).commitCreditsToPurse(
        user.address,
        owner.address, // purse
        ethers.utils.parseEther("50"),
        validatorOwner.address // validator
      );
      
      // Check credits were deducted
      expect(await creditSystem.userCredits(user.address)).to.equal(ethers.utils.parseEther("50"));
      
      // Check purse credits
      const purseCredit = await creditSystem.getUserPurseCredit(user.address, owner.address);
      expect(purseCredit.amount).to.equal(ethers.utils.parseEther("50"));
      expect(purseCredit.validator).to.equal(validatorOwner.address);
      expect(purseCredit.active).to.be.true;
    });
    
    it("should handle defaults correctly with validator", async () => {
      // Setup
      const creditAmount = ethers.utils.parseEther("100");
      await creditSystem.connect(owner).assignCredits(user.address, creditAmount);
      await creditSystem.connect(owner).authorizeFactory(owner.address);
      await creditSystem.connect(owner).registerPurse(owner.address);
      
      // Stake tokens for validator if needed
      await token.connect(validatorOwner).approve(validator.address, ethers.utils.parseEther("50"));
      await validator.connect(validatorOwner).addStake(ethers.utils.parseEther("50"));
      
      // Commit credits with validator
      await creditSystem.connect(owner).commitCreditsToPurse(
        user.address,
        owner.address, // purse
        ethers.utils.parseEther("50"),
        validatorOwner.address // validator
      );
      
      // Get initial validator credits
      const initialValidatorCredits = await creditSystem.userCredits(validatorOwner.address);
      
      // Process default
      await creditSystem.connect(owner).handleUserDefault(
        user.address,
        owner.address, // purse
        ethers.utils.parseEther("25"),
        token.address, // token address
        otherUser.address // recipient
      );
      
      // Check validator defaulter history
      const defaultHistory = await creditSystem.getValidatorDefaulterHistory(
        validatorOwner.address,
        user.address
      );
      expect(defaultHistory).to.equal(ethers.utils.parseEther("25"));
      
      
      // Check recipient received tokens
      expect(await token.balanceOf(otherUser.address)).to.equal(ethers.utils.parseEther("25"));
    });
    
    it("should handle defaults correctly without validator", async () => {
      // Setup
      const creditAmount = ethers.utils.parseEther("100");
      await creditSystem.connect(owner).assignCredits(user.address, creditAmount);
      await creditSystem.connect(owner).authorizeFactory(owner.address);
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
      await creditSystem.connect(owner).assignCredits(user.address, creditAmount);
      await creditSystem.connect(owner).authorizeFactory(owner.address);
      await creditSystem.connect(owner).registerPurse(owner.address);
      
      // Get initial validator credits before commit
      const initialValidatorCredits = await creditSystem.userCredits(validatorOwner.address);
      
      // Commit credits with validator
      await creditSystem.connect(owner).commitCreditsToPurse(
        user.address,
        owner.address, // purse
        ethers.utils.parseEther("50"),
        validatorOwner.address // validator
      );
      
      // Release credits
      await creditSystem.connect(owner).releasePurseCredits(
        user.address,
        owner.address // purse
      );
      
      // Check credits were returned to validator (should have increased by 50 ETH)
      const finalValidatorCredits = await creditSystem.userCredits(validatorOwner.address);
      expect(finalValidatorCredits.sub(initialValidatorCredits)).to.equal(ethers.utils.parseEther("50"));
      
      // Check purse credit no longer active
      const purseCredit = await creditSystem.getUserPurseCredit(user.address, owner.address);
      expect(purseCredit.active).to.be.false;
    });
    
    it("should release credits properly without validator", async () => {
      // Setup
      const creditAmount = ethers.utils.parseEther("100");
      await creditSystem.connect(owner).assignCredits(user.address, creditAmount);
      await creditSystem.connect(owner).authorizeFactory(owner.address);
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