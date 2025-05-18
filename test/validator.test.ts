import { ethers } from "hardhat";
import { expect } from "chai";
import { Contract } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("Validator", function() {
  let validator: Contract;
  let validatorFactory: Contract;
  let creditSystem: Contract;
  let token: Contract;
  let tokenRegistry: Contract;
  let owner: SignerWithAddress;
  let validatorOwner: SignerWithAddress;
  let user: SignerWithAddress;
  let admin: SignerWithAddress;
  let newValidatorOwner: SignerWithAddress;

  // Helper function to setup a mock purse and commitments
  async function setupMockPurseAndCommitment(userAddr: string, amount: any, validatorAddr: string) {
    await creditSystem.connect(owner).authorizeFactory(owner.address, false);
    await creditSystem.connect(owner).registerPurse(owner.address);
    await creditSystem.connect(owner).commitCreditsToPurse(
      userAddr,
      owner.address, // purse
      amount,
      validatorAddr
    );
  }

  beforeEach(async function() {
    [owner, user, admin, validatorOwner, newValidatorOwner] = await ethers.getSigners();
    
    // Deploy token
    const Token = await ethers.getContractFactory("MockERC20");
    token = await Token.deploy("Test Token", "TST", 18);
    await token.deployed();
    
    // Mint tokens to owner
    await token.mint(owner.address, ethers.utils.parseEther("10000"));
    
    // Deploy token registry
    const TokenRegistryFactory = await ethers.getContractFactory("TokenRegistry");
    tokenRegistry = await TokenRegistryFactory.deploy();
    await tokenRegistry.deployed();
    
    // Whitelist token in registry
    await tokenRegistry.connect(owner).setTokenWhitelist(token.address, true);
    
    // Deploy credit system
    const CreditSystem = await ethers.getContractFactory("CreditSystem");
    creditSystem = await CreditSystem.deploy(
      ethers.constants.AddressZero, // Temporary zero address
      tokenRegistry.address
    );
    await creditSystem.deployed();

    // Deploy validator factory
    const ValidatorFactory = await ethers.getContractFactory("ValidatorFactory");
    validatorFactory = await ValidatorFactory.deploy(
      creditSystem.address,
      ethers.utils.parseEther("1000"), // Min stake
      1000, // Max fee percentage (10%)
      tokenRegistry.address // Token registry
    );
    await validatorFactory.deployed();

    // Update credit system with validator factory
    await creditSystem.connect(owner).authorizeFactory(validatorFactory.address, true);
    
    // Fund validator owner with tokens
    await token.connect(owner).transfer(validatorOwner.address, ethers.utils.parseEther("2000"));
    
    // Create a validator
    await token.connect(validatorOwner).approve(validatorFactory.address, ethers.utils.parseEther("2000"));
    await validatorFactory.connect(validatorOwner).createValidator(
      50,  // fee percentage (0.5% - maximum allowed)
      token.address, // staked token
      ethers.utils.parseEther("1000") // initial stake amount
    );
    
    // Get the validator contract
    const validatorContractAddress = await validatorFactory.getValidatorContract(validatorOwner.address);
    const Validator = await ethers.getContractFactory("Validator");
    validator = Validator.attach(validatorContractAddress);
  });

  it("should validate a user", async function() {
    // Validator validates user
    await validator.connect(validatorOwner).validateUser(user.address, ethers.utils.parseEther("100"));
    
    // Check if user is validated
    expect(await validator.isUserValidated(user.address)).to.be.true;
    
    // Check user credits
    // Fee is 0.5% (50 basis points), so user gets 99.5% of credits
    const expectedCredits = ethers.utils.parseEther("100").mul(9950).div(10000); // 99.5%
    expect(await creditSystem.userCredits(user.address)).to.equal(expectedCredits);
  });

  it("should invalidate a user", async function() {
    // First validate the user
    await validator.connect(validatorOwner).validateUser(user.address, ethers.utils.parseEther("100"));
    
    // Then invalidate the user
    await validator.connect(validatorOwner).invalidateUser(user.address);
    
    // Check if user is no longer validated
    expect(await validator.isUserValidated(user.address)).to.be.false;
    
    // Check user credits are back to 0
    expect(await creditSystem.userCredits(user.address)).to.equal(0);
  });

  it("should automatically authorize validator contract in credit system during creation", async function() {
    // Get the validator contract address
    const validatorContractAddress = await validatorFactory.getValidatorContract(validatorOwner.address);
    
    // Create a new user to validate, which will call setUserValidator from the validator contract
    // This will fail if the validator is not authorized in the credit system
    await validator.connect(validatorOwner).validateUser(admin.address, ethers.utils.parseEther("50"));
    
    // Check if user was successfully validated
    expect(await validator.isUserValidated(admin.address)).to.be.true;
    
    // Verify the user validator relationship in the credit system
    expect(await creditSystem.userValidators(admin.address)).to.equal(validatorContractAddress);
  });

  it("should allow validator to withdraw stake", async function() {
    const initialBalance = await token.balanceOf(validatorOwner.address);
    
    // Withdraw 100 tokens
    await validator.connect(validatorOwner).withdrawStake(ethers.utils.parseEther("100"));
    
    // Check validator owner balance increased
    expect(await token.balanceOf(validatorOwner.address)).to.equal(
      initialBalance.add(ethers.utils.parseEther("100"))
    );
    
    // Check validator credits reduced
    expect(await creditSystem.userCredits(validatorOwner.address)).to.equal(
      ethers.utils.parseEther("900") // 1000 - 100
    );
  });

  it("should allow validator to add stake", async function() {
    const initialCredits = await creditSystem.userCredits(validatorOwner.address);
    
    // Approve token transfer
    await token.connect(validatorOwner).approve(validator.address, ethers.utils.parseEther("100"));
    
    // Add 100 tokens to stake
    await validator.connect(validatorOwner).addStake(ethers.utils.parseEther("100"));
    
    // Check validator credits increased
    expect(await creditSystem.userCredits(validatorOwner.address)).to.equal(
      initialCredits.add(ethers.utils.parseEther("100"))
    );
  });

  it("should handle defaulter penalty correctly", async function() {
    // Validate user first
    await validator.connect(validatorOwner).validateUser(user.address, ethers.utils.parseEther("100"));
    
    // Check validator credits after validation (should be reduced by 100)
    const validatorCreditsAfterValidation = await creditSystem.userCredits(validatorOwner.address);
    // Validator keeps 0.5% fee from the 100 validation
    const validatorFee = ethers.utils.parseEther("100").mul(50).div(10000); // 0.5%
    expect(validatorCreditsAfterValidation).to.equal(
        ethers.utils.parseEther("1000").sub(ethers.utils.parseEther("100")).add(validatorFee)
    ); // 1000 - 100 + 0.5
    
    // Setup a mock purse
    const penaltyAmount = ethers.utils.parseEther("50");
    await setupMockPurseAndCommitment(user.address, penaltyAmount, validator.address);
    
    // Call handleDefaulterPenalty
    await creditSystem.connect(owner).handleUserDefault(
      user.address, 
      owner.address, // purse
      penaltyAmount,
      admin.address
    );
    
    // Check validator credits were NOT reduced further by the penalty
    const finalValidatorCredits = await creditSystem.userCredits(validatorOwner.address);
    expect(finalValidatorCredits).to.equal(
        ethers.utils.parseEther("1000")
        .sub(ethers.utils.parseEther("100"))
        .add(validatorFee)
    ); // 900.5
    
    // Check admin received tokens
    expect(await token.balanceOf(admin.address)).to.equal(penaltyAmount);
  });

  it("should not apply penalty when defaulter is the recipient", async function() {
    // Validate user first
    await validator.connect(validatorOwner).validateUser(user.address, ethers.utils.parseEther("100"));
    
    // Get initial balances
    const initialUserBalance = await token.balanceOf(user.address);
    const initialValidatorBalance = await token.balanceOf(validator.address);
    const initialValidatorCredits = await creditSystem.userCredits(validatorOwner.address);
    
    // Setup a mock purse with commitment
    const defaultAmount = ethers.utils.parseEther("50");
    await setupMockPurseAndCommitment(user.address, defaultAmount, validator.address);
    
    // Call handleUserDefault with user as both defaulter and recipient
    await creditSystem.connect(owner).handleUserDefault(
      user.address, // defaulter
      owner.address, // purse
      defaultAmount,
      user.address // recipient is same as defaulter
    );
    
    // Verify balances haven't changed
    expect(await token.balanceOf(user.address)).to.equal(initialUserBalance);
    expect(await token.balanceOf(validator.address)).to.equal(initialValidatorBalance);
    
    // The validator credits should remain unchanged when defaulter is the recipient
    const finalValidatorCredits = await creditSystem.userCredits(validatorOwner.address);
    expect(finalValidatorCredits).to.equal(initialValidatorCredits);
  });

  it("should allow factory to create validator and validator to validate user", async function() {
    // Fund new validator owner with tokens
    await token.connect(owner).transfer(newValidatorOwner.address, ethers.utils.parseEther("2000"));
    
    // Approve tokens for creating a validator
    await token.connect(newValidatorOwner).approve(validatorFactory.address, ethers.utils.parseEther("1500"));
    
    // Create a new validator through the factory
    await validatorFactory.connect(newValidatorOwner).createValidator(
      100,  // fee percentage (1% - within allowed limit)
      token.address, // staked token
      ethers.utils.parseEther("1500") // initial stake amount
    );
    
    // Get the new validator contract
    const newValidatorContractAddress = await validatorFactory.getValidatorContract(newValidatorOwner.address);
    const ValidatorContract = await ethers.getContractFactory("Validator");
    const newValidator = ValidatorContract.attach(newValidatorContractAddress);
    
    // Verify validator is registered in the system
    expect(await validatorFactory.isValidatorContract(newValidatorContractAddress)).to.be.true;
    
    // Verify validator has been given appropriate credits
    expect(await creditSystem.userCredits(newValidatorOwner.address)).to.equal(ethers.utils.parseEther("1500"));
    
    // New validator validates a user
    await newValidator.connect(newValidatorOwner).validateUser(admin.address, ethers.utils.parseEther("200"));
    
    // Check if user is validated
    expect(await newValidator.isUserValidated(admin.address)).to.be.true;
    
    // Check user credits (1% fee means user gets 99% of credits)
    const expectedCredits = ethers.utils.parseEther("200").mul(9900).div(10000); // 99%
    expect(await creditSystem.userCredits(admin.address)).to.equal(expectedCredits);
    
    // Verify the user validator relationship in the credit system
    expect(await creditSystem.userValidators(admin.address)).to.equal(newValidatorContractAddress);
    expect(await creditSystem.isUserValidatedBy(admin.address, newValidatorContractAddress)).to.be.true;
  });
}); 