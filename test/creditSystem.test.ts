import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract, BigNumber } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { Roles } from "../contracts/access/Roles";

describe("CreditSystem", () => {
  let creditSystem: Contract;
  let priceOracle: Contract;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;
  let factory: SignerWithAddress;
  let token: Contract;
  let lpToken: Contract;
  let notLPToken: Contract;
  let validatorFactory: Contract;
  let validator: Contract;
  let validatorOwner: SignerWithAddress;
  let otherUser: SignerWithAddress;

  const DECIMALS = 8;
  const INITIAL_PRICE = ethers.utils.parseUnits("2000", 8);

  beforeEach(async () => {
    [owner, user, factory, otherUser] = await ethers.getSigners();

    // Deploy mock token
    const TokenFactory = await ethers.getContractFactory("Token");
    token = await TokenFactory.deploy();

    // Deploy mock LP token
    const MockLPTokenFactory = await ethers.getContractFactory("MockLPToken");
    lpToken = await MockLPTokenFactory.deploy(token.address, token.address);

    // Deploy mock non-LP token
   
    notLPToken = await MockLPTokenFactory.deploy(token.address, token.address);

    // Deploy price oracle
    const MockPriceOracleFactory = await ethers.getContractFactory("MockPriceOracle");
    priceOracle = await MockPriceOracleFactory.deploy();

    // Deploy credit system first without validator factory
    const CreditSystemFactory = await ethers.getContractFactory("CreditSystem");
    creditSystem = await CreditSystemFactory.deploy(
        token.address,
        token.address,
        priceOracle.address,
        ethers.constants.AddressZero  // Temporary zero address
    );

    // Deploy validator factory
    const ValidatorFactoryFactory = await ethers.getContractFactory("ValidatorFactory");
    validatorFactory = await ValidatorFactoryFactory.deploy(
        creditSystem.address,
        ethers.utils.parseUnits("1000", "ether"),
        1000
    );

    // Update credit system's validator factory
    await creditSystem.connect(owner).setValidatorFactory(validatorFactory.address);

    // Setup credit system roles
    await creditSystem.grantRole(ethers.constants.HashZero, owner.address);
    await creditSystem.grantRole(Roles.ADMIN_ROLE, owner.address);

    // Setup price oracle with owner
    await priceOracle.connect(owner).setPrice(token.address, INITIAL_PRICE);
    await priceOracle.connect(owner).setPrice(lpToken.address, INITIAL_PRICE);
    await priceOracle.connect(owner).setLastUpdateTime(token.address, Math.floor(Date.now() / 1000));
    await priceOracle.connect(owner).setLastUpdateTime(lpToken.address, Math.floor(Date.now() / 1000));
    await priceOracle.connect(owner).setSupportedStatus(token.address, true);
    await priceOracle.connect(owner).setSupportedStatus(lpToken.address, true);

    // Setup initial token balances
    await token.transfer(user.address, ethers.utils.parseEther("1000"));

    // Setup validator
    [, , , , validatorOwner] = await ethers.getSigners();
    await token.transfer(validatorOwner.address, ethers.utils.parseUnits("2000", "ether"));
    await token.connect(validatorOwner).approve(validatorFactory.address, ethers.utils.parseUnits("1000", "ether"));
    await validatorFactory.connect(validatorOwner).createValidator(500, token.address);

    const validatorAddress = await validatorFactory.getValidatorContract(validatorOwner.address);
    validator = await ethers.getContractAt("Validator", validatorAddress);
  });

  describe("LP Staking and Credits", () => {
    beforeEach(async () => {
      // Setup LP pool
      await creditSystem.whitelistLPPool(
        lpToken.address,
        5000, // 50% credit ratio
        7 * 24 * 60 * 60, // 7 days min stake
        ethers.utils.parseEther("1000000") // 1M max credit limit
      );

      // Transfer LP tokens to user
      await lpToken.transfer(user.address, ethers.utils.parseEther("100"));
      await lpToken.connect(user).approve(creditSystem.address, ethers.utils.parseEther("100"));
    });

    it("should allow staking LP tokens and receive credits", async () => {
      const stakeAmount = ethers.utils.parseEther("10");
      await creditSystem.connect(user).stakeLPToken(lpToken.address, stakeAmount);
      
      const userCredits = await creditSystem.userCredits(user.address);
      expect(userCredits).to.be.gt(0);
      
      const stake = await creditSystem.userLPStakes(user.address, lpToken.address);
      expect(stake.amount).to.equal(stakeAmount);
    });

    it("should not allow unstaking before minimum time", async () => {
      await creditSystem.whitelistLPPool(lpToken.address, 5000, 7 * 24 * 60 * 60, 1000000);
      await creditSystem.connect(user).stakeLPToken(lpToken.address, 100);
      
      await expect(
        creditSystem.connect(user).unstakeLPToken(lpToken.address)
      ).to.be.revertedWithCustomError(creditSystem, "MinimumStakeTimeNotMet");
    });

    it("should calculate LP credits correctly", async () => {
      const stakeAmount = ethers.utils.parseEther("1");
      await priceOracle.setPrice(lpToken.address, INITIAL_PRICE);
      await priceOracle.setSupportedStatus(lpToken.address, true);
      
      const credits = await creditSystem.calculateLPCredits(lpToken.address, stakeAmount);
      expect(credits).to.be.gt(0);
    });

    it("should revert when LP token is not whitelisted", async () => {
      await expect(
        creditSystem.calculateLPCredits(notLPToken.address, 100)
      ).to.be.revertedWithCustomError(creditSystem, "LPNotWhitelistedForCredits");
    });

    it("should not allow unstaking with insufficient credits", async () => {
      const stakeAmount = ethers.utils.parseEther("10");
      await creditSystem.connect(user).stakeLPToken(lpToken.address, stakeAmount);
      
      // Reduce user's credits below the staked amount
      await creditSystem.connect(owner).authorizeFactory(owner.address);
      await creditSystem.connect(owner).reduceCredits(user.address, stakeAmount);
      
      // Increase time to pass minimum stake time
      await ethers.provider.send("evm_increaseTime", [7 * 24 * 60 * 60 + 1]);
      await ethers.provider.send("evm_mine", []);

      await expect(
        creditSystem.connect(user).unstakeLPToken(lpToken.address)
      ).to.be.revertedWithCustomError(creditSystem, "InsufficientCredits");
    });
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
    it("should allow admin to pause and unpause", async () => {
      await creditSystem.connect(owner).pause();
      expect(await creditSystem.paused()).to.be.true;

      await creditSystem.connect(owner).unpause();
      expect(await creditSystem.paused()).to.be.false;
    });

    it("should allow admin to whitelist LP pool", async () => {
      await creditSystem.connect(owner).whitelistLPPool(
        lpToken.address,
        5000,
        7 * 24 * 60 * 60,
        ethers.utils.parseEther("1000000")
      );

      const pool = await creditSystem.whitelistedPools(lpToken.address);
      expect(pool.isWhitelisted).to.be.true;
      expect(pool.creditRatio).to.equal(5000);
    });
  });

  describe("Default Handling", () => {
    it("should handle defaulter penalties correctly", async () => {
        // Setup
        const defaultAmount = ethers.utils.parseUnits("10", "ether");
        await creditSystem.connect(owner).assignCredits(user.address, defaultAmount.mul(2));
        
        // Create mock purse
        const mockPurse = owner;
        await creditSystem.authorizeFactory(owner.address);
        await creditSystem.registerPurse(mockPurse.address);

        // Validate the user with the validator
        await validator.connect(validatorOwner).validateUser(user.address);
        
        // Link user to validator in credit system
        await creditSystem.connect(owner).setUserValidator(user.address, validatorOwner.address);

        // Get initial balances
        const initialOwnerBalance = await token.balanceOf(owner.address);
        const initialValidatorStake = (await validator.getValidatorData()).stakedAmount;

        // Test default penalty with different recipient
        await creditSystem.connect(mockPurse).reduceCreditsForDefault(
            user.address,    // defaulter
            owner.address,   // different recipient
            defaultAmount,
            validatorOwner.address
        );

        // Verify credits reduced
        expect(await creditSystem.userCredits(user.address)).to.equal(defaultAmount);

        // Verify validator stake reduced
        const finalValidatorStake = (await validator.getValidatorData()).stakedAmount;
        expect(initialValidatorStake.sub(finalValidatorStake)).to.equal(defaultAmount);

        // Verify recipient received the penalty amount
        const finalOwnerBalance = await token.balanceOf(owner.address);
        expect(finalOwnerBalance.sub(initialOwnerBalance)).to.equal(defaultAmount);
    });

    it("should not reduce validator stake when defaulter is recipient", async () => {
        const defaultAmount = ethers.utils.parseUnits("10", "ether");
        await creditSystem.connect(owner).assignCredits(user.address, defaultAmount.mul(2));
        
        const mockPurse = owner;
        await creditSystem.authorizeFactory(owner.address);
        await creditSystem.registerPurse(mockPurse.address);

           // Validate the user with the validator
         await validator.connect(validatorOwner).validateUser(user.address);
        
          // Link user to validator in credit system
          await creditSystem.connect(owner).setUserValidator(user.address, validatorOwner.address);

        // Test with same defaulter and recipient
        await creditSystem.connect(mockPurse).reduceCreditsForDefault(
            user.address,
            user.address, // Same as defaulter
            defaultAmount,
            validatorOwner.address
        );

        const validatorData = await validator.getValidatorData();
        expect(validatorData.stakedAmount).to.equal(
            ethers.utils.parseUnits("1000", "ether") 
        );
    });

    it("should emit correct events", async () => {
      const defaultAmount = ethers.utils.parseUnits("10", "ether");
      await creditSystem.connect(owner).assignCredits(user.address, defaultAmount.mul(2));
      
      const mockPurse = owner;
      await creditSystem.authorizeFactory(owner.address);
      await creditSystem.registerPurse(mockPurse.address);

      // Validate the user with the validator
      await validator.connect(validatorOwner).validateUser(user.address);
          
      // Link user to validator in credit system
      await creditSystem.connect(owner).setUserValidator(user.address, validatorOwner.address);

      // The StakeReduced event is not emitted because we're using the same address
      // for defaulter and recipient. Per the Validator contract's handleDefaulterPenalty function,
      // stake is only reduced when defaulter != recipient
      await expect(
        creditSystem.connect(mockPurse).reduceCreditsForDefault(
          user.address,
          owner.address, 
          defaultAmount,
          validatorOwner.address
        )
      ).to.emit(creditSystem, "CreditsReduced")
       .withArgs(user.address, defaultAmount, "Default penalty")
       .and.to.emit(validator, "StakeReduced")
       .withArgs(defaultAmount, "User default");
    });

    it("should fail for unauthorized purse", async () => {
      await expect(
        creditSystem.connect(user).reduceCreditsForDefault(
          user.address,
          user.address,
          100,
          validatorOwner.address
        )
      ).to.be.revertedWithCustomError(creditSystem, "NotAuthorizedPurse");
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
      ).to.be.revertedWithCustomError(creditSystem, "NoValidatorFound");
    });
  });

  describe("Validator Factory Management", () => {
    it("should allow admin to set validator factory", async () => {
      const ValidatorFactoryFactory = await ethers.getContractFactory("ValidatorFactory");
      const newValidatorFactory = await ValidatorFactoryFactory.deploy(
        creditSystem.address,
        ethers.utils.parseUnits("1000", "ether"),
        1000
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
      ).to.be.revertedWithCustomError(creditSystem, "InvalidValidatorFactory");
    });

    it("should not allow setting same address as current validator factory", async () => {
      await expect(
        creditSystem.connect(owner).setValidatorFactory(await creditSystem.validatorFactory())
      ).to.be.revertedWithCustomError(creditSystem, "SameValidatorFactory");
    });

    it("should not allow unauthorized reduction of credits", async () => {
      await expect(
        creditSystem.connect(user).reduceCredits(user.address, 100)
      ).to.be.revertedWithCustomError(creditSystem, "NotAuthorizedFactory");
    });

    it("should not allow reducing more credits than available", async () => {
      await creditSystem.connect(owner).authorizeFactory(factory.address);
      await expect(
        creditSystem.connect(factory).reduceCredits(user.address, 100)
      ).to.be.revertedWithCustomError(creditSystem, "InsufficientCredits");
    });
  });
}); 