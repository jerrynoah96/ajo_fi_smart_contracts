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

  beforeEach(async function() {
    [owner, validatorOwner, user, admin] = await ethers.getSigners();

    // Deploy a mock token
    const Token = await ethers.getContractFactory("MockERC20");
    token = await Token.deploy("Test Token", "TEST", 18);
    await token.deployed();
    
    // Mint tokens to owner
    await token.mint(owner.address, ethers.utils.parseEther("5000"));

    // Deploy TokenRegistry
    const TokenRegistryFactory = await ethers.getContractFactory("TokenRegistry");
    tokenRegistry = await TokenRegistryFactory.deploy();
    await tokenRegistry.deployed();

    // Whitelist token in registry
    await tokenRegistry.connect(owner).setTokenWhitelist(token.address, true);

    // Deploy credit system with temporary zero address for validator factory
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
      token.address // Default whitelisted token
    );
    await validatorFactory.deployed();

    // Update credit system with validator factory
    await creditSystem.connect(owner).authorizeFactory(validatorFactory.address, true);
    
    // Authorize validator factory in credit system
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
    
    // Authorize the validator contract in credit system since it needs to call setUserValidator
    await creditSystem.connect(owner).authorizeFactory(validatorContractAddress, false);
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
    await creditSystem.connect(owner).authorizeFactory(owner.address, false);
    await creditSystem.connect(owner).registerPurse(owner.address);
    
    // Commit user credits to purse
    await creditSystem.connect(owner).commitCreditsToPurse(
      user.address,
      owner.address, // purse
      ethers.utils.parseEther("50"),
      validator.address
    );
    
    // Call handleDefaulterPenalty
    const penaltyAmount = ethers.utils.parseEther("50");
    await creditSystem.connect(owner).handleUserDefault(
      user.address, 
      owner.address, // purse
      penaltyAmount,
      token.address, // token address
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
    
    // Setup a mock purse
    await creditSystem.connect(owner).authorizeFactory(owner.address, false);
    await creditSystem.connect(owner).registerPurse(owner.address);
    
    // Commit user credits to purse
    await creditSystem.connect(owner).commitCreditsToPurse(
      user.address,
      owner.address, // purse
      ethers.utils.parseEther("50"),
      validator.address
    );
    
    // Get initial balances
    const initialUserBalance = await token.balanceOf(user.address);
    const initialValidatorBalance = await token.balanceOf(validator.address);
    
    // Call handleUserDefault with user as both defaulter and recipient
    await creditSystem.connect(owner).handleUserDefault(
      user.address, // defaulter
      owner.address, // purse
      ethers.utils.parseEther("50"),
      token.address,
      user.address // recipient is same as defaulter
    );
    
    // Verify balances haven't changed
    expect(await token.balanceOf(user.address)).to.equal(initialUserBalance);
    expect(await token.balanceOf(validator.address)).to.equal(initialValidatorBalance);
  });
}); 