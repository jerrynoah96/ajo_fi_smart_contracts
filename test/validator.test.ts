import { ethers } from "hardhat";
import { expect } from "chai";
import { Contract } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("Validator", function() {
  let validator: Contract;
  let validatorFactory: Contract;
  let creditSystem: Contract;
  let token: Contract;
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

    // Deploy mock price oracle with fully qualified name
    const MockPriceOracle = await ethers.getContractFactory("contracts/test/MockPriceOracle.sol:MockPriceOracle");
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
    await creditSystem.setValidatorFactory(validatorFactory.address);

    // Fund validator owner with tokens
    await token.connect(owner).transfer(validatorOwner.address, ethers.utils.parseEther("2000"));
    
    // Create a validator
    await token.connect(validatorOwner).approve(validatorFactory.address, ethers.utils.parseEther("2000"));
    await validatorFactory.connect(validatorOwner).createValidator(500, token.address);
    
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
    expect(await creditSystem.userCredits(user.address)).to.equal(ethers.utils.parseEther("100"));
  });

  it("should invalidate a user", async function() {
    // First validate the user
    await validator.connect(validatorOwner).validateUser(user.address, ethers.utils.parseEther("100"));
    
    // Then invalidate the user
    await validator.connect(validatorOwner).invalidateUser(user.address, ethers.utils.parseEther("100"));
    
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
    // Admin needs to authorize the credit system to call handleDefaulterPenalty
    await creditSystem.connect(owner).authorizeFactory(owner.address);
    
    // Create a mock purse to call reduceCreditsForDefault
    const mockPurse = owner.address;
    await creditSystem.connect(owner).registerPurse(mockPurse);
    
    // First validate the user
    await validator.connect(validatorOwner).validateUser(user.address, ethers.utils.parseEther("100"));
    
    // Set user's validator in credit system
    await creditSystem.connect(owner).setUserValidator(user.address, validatorOwner.address);
    
    // Call reduceCreditsForDefault to trigger handleDefaulterPenalty
    await creditSystem.connect(owner).reduceCreditsForDefault(
      user.address,
      admin.address, // recipient
      ethers.utils.parseEther("50"),
      validatorOwner.address
    );
    
    // Check user credits reduced
    expect(await creditSystem.userCredits(user.address)).to.equal(ethers.utils.parseEther("50"));
    
    // Check validator credits reduced
    expect(await creditSystem.userCredits(validatorOwner.address)).to.equal(ethers.utils.parseEther("950"));
    
    // Check admin received tokens
    expect(await token.balanceOf(admin.address)).to.equal(ethers.utils.parseEther("50"));
  });
}); 