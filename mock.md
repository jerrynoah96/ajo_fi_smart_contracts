Due to the immutability of smart contracts, it’s crucial that they are tested thoroughly before they are deployed. When it comes to writing automated tests, developers have a couple of options:

Solidity Tests
Javascript/Python/other language tests
Often, it’s useful to test contracts both ways, and you can see from this sample testing repo that it can be quite useful to test both with JavaScript and Solidity. Most dApps interact with contracts in this way, so they’re useful tests. Solidity, on the other hand, should most likely be used when you’re testing a contract/library where the main point of usage comes from another on-chain contract.

Obviously, to be extra thorough, use both. If you have a simple smart contract like:

pragma solidity >=0.5.0;

contract Background {
    uint[] private values;
    
    function storeValue(uint value) public {
        values.push(value);
    }
    
    function getValue(uint initial) public view returns(uint) {
        return values[initial];
    }
    
    function getNumberOfValues() public view returns(uint) {
        return values.length;
    }
}
It can be pretty simple to write some Solidity tests like:

pragma solidity >=0.5.0;

import "truffle/Assert.sol";
import "truffle/DeployedAddresses.sol";
import "../../../contracts/Background.sol";

contract TestBackground {
    Background public background;
    
    // Run before every test function
    function beforeEach() public {
        background = new Background();
    }
    
    // Test that it stores a value correctly
    function testItStoresAValue() public {
        uint value = 5;
        background.storeValue(value);
        uint result = background.getValue(0);
        Assert.equal(result, value, "It should store the correct value");
    }
    
    // Test that it gets the correct number of values
    function testItGetsCorrectNumberOfValues() public {
        background.storeValue(99);
        uint newSize = background.getNumberOfValues();
        Assert.equal(newSize, 1, "It should increase the size");
    }
    
    // Test that it stores multiple values correctly
    function testItStoresMultipleValues() public {
        for (uint8 i = 0; i < 10; i++) {
            uint value = i;
            background.storeValue(value);
            uint result = background.getValue(i);
            Assert.equal(result, value, "It should store the correct value for multiple values");
        }
    }
}
For those who want to learn more about testing smart contracts in general, here are a few additional sources you can check out.

Ethereum.org
Truffle
Hardhat and Waffle
You’ll need to be familiar with at least Truffle or HardHat (formerly known as Buidler) for the rest of this documentation. You can learn how to deploy and test Chainlink smart contracts with Truffle from some of our previous articles as well. Also, ideally you’ll already understand that unit tests and integrations tests are different, and they each have very important features.

However, when working with Chainlink oracles and on-chain data, testing can get a little tricky. Some conventional methods don’t quite cover every outcome. In this article, we are going to be focusing almost exclusively on JavaScript tests, but these methods can of course be integrated with Solidity if you’d prefer to run your tests that way as well.

The Simplest Way to Test Chainlink Smart Contracts
The simplest way to test Chainlink smart contracts is to just use a testnet! Most projects will deploy to a testnet before going mainnet, but they can also just keep redeploying to iterate over their tests, since testnet ETH is free. Kovan or Rinkeby at the moment have plenty of Chainlink nodes, price feeds, and really anything else that you’re looking for. In your test files, be sure to obtain some testnet LINK and ETH and you’ll be good to go. Another easy way is to just run your own Chainlink node and have it monitor a local chain that you’re running.

Running tests on a testnet is not particularly fast when compared to a local blockchain. You also run the risk of hitting faucet limits. Let’s look at how you can test your Chainlink smart contracts locally.

Using Forking
Gelato is an example of a project that uses forking and Chainlink.

Chainlink Price Feeds are one of the most popular services that Chainlink provides. Price feed oracle networks aggregate data from decentralized independent sources and create a source of definitive truth on-chain. The question is, how do you test that you’re correctly consuming this price data?

Do you deploy your own price feed?
Do you just ignore testing the price feeds?
Do you skip tests altogether and pray your dApp doesn’t fall apart?
Now, you’re more than welcome to do that third bullet, but this is strongly discouraged, especially since testing them is a cinch! All we need to do is fork the chain we are working with. If you haven’t worked with Chainlink Price Feeds before, be sure to check out our documentation. All the code for this section can be found in the chainlink-hardhat repo. For those unfamiliar with Hardhat, it’s a Truffle-like setup with a number of nice, quality of life differences.

Let’s say we have a contract that uses Chainlink Price Feeds and looks something like this:

pragma solidity ^0.6.6;

import "@chainlink/contracts/src/v0.6/interfaces/AggregatorV3Interface.sol";

contract PriceConsumerV3 {

    AggregatorV3Interface internal priceFeed;

    /**
     * Network: Mainnet
     * Aggregator: ETH/USD
     * Address: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
     */
    constructor() public {
        priceFeed = AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
    }

    /**
     * Returns the latest price
     */
    function getLatestPrice() public view returns (int) {
        (
            uint80 roundID, 
            int price,
            uint startedAt,
            uint timeStamp,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        // If the round is not complete yet, timestamp is 0
        require(timeStamp > 0, "Round not complete");
        return price;
    }
}
First off, yes, we are using a mainnet price feed address for this, but don’t be alarmed. This is intentional. Normally, to interact with mainnet price feeds, we’d have to be deployed on mainnet. However, we can actually fork chains when running our tests to see what contracts would look like if they were deployed on mainnet, without actually deploying them on mainnet. Using HardHat’s setup, we can just add to our hardhat.config.js file that we’d like to fork from this network.

Here’s what our hardhat.config.js file looks like:

require("@nomiclabs/hardhat-waffle")

module.exports = {
  defaultNetwork: "hardhat",
  networks: {
    hardhat: {
      forking: {
        url: process.env.ALCHEMY_MAINNET_RPC_URL
      }
    },
    kovan: {
      url: process.env.KOVAN_RPC_URL,
      accounts: {
        mnemonic: process.env.MNEMONIC
      }
    }
  },
  solidity: "0.6.6",
}
You’ll see that our hardhat network has a forking key. This means that when we deploy a script on the hardhat network, we will first fork what’s in our RPC_URL (set to ALCHEMY_MAINNET_RPC_URL at the moment) and then deploy it to that network. This is great for testing, since we can actually deploy our smart contract to a forked version of mainnet and test with our price feeds to it.

Try it yourself!

git clone https://github.com/PatrickAlphaC/chainlink-hardhat

cd chainlink-hardhat

yarn

npx hardhat test

This will test our smart contract by deploying the smart contracts to our forked mainnet. Truffle teams also has a feature where you can fork mainnet and test based off of the forked network.

Using Mocks
Aave is an example of a project that uses mocks and Chainlink for tests.

Unfortunately, forking mainnet to test interacting with Chainlink oracles won’t work. This is because we don’t have any Chainlink oracles monitoring our forked network. So we often need to look somewhere else. Testing objects and services with dependencies is nothing new but can present difficulties when writing unit tests. A good solution is to mock any dependencies, and focus the tests solely on the contract itself.

Mocking is essentially replacing the complicated objects with simpler ones that dummy the functionality of what we are looking to do. This is great for working with projects that make use of the Chainlink API Call, Chainlink VRF, or any Chainlink External Adapter. Often, engineers will create a mocks file in their tests folder which has all the dummy mocks. We can see a simple version of mocking an ERC20 with a file like this, which simulates working with a real ERC20 when we are testing:

pragma solidity ^0.6.10;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor() public ERC20("MOCK", "MCK") {
        _mint(msg.sender, 100*10**18);
    }
}
A more relatable mock would be working with a mock Chainlink consumer, or a smart contract that interacts with a Chainlink oracle. That would look something like this:

pragma solidity ^0.6.10;

import "@chainlink/contracts/src/v0.6/ChainlinkClient.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockOracleClient is ChainlinkClient, Ownable {
    event Tweet(string content);

    constructor(address _link) public {
        link = _link;
    }

    function sendTweet(string memory content) external override onlyGovernance {
        emit Tweet(content);
    }
}
In this mock, we have the sendTweet function—in a _real _Chainlink consumer contract, it would make a Chainlink API request to a Chainlink node to “send a tweet”. However, in our mock, we just emit a log that a tweet was sent, and this can be a simple way to dummy getting a response to a Chainlink node. You can see all these mocks in action in the tweether repo. That repo uses a combination of Truffle and Hardhat as well, so you can see the two work well together.

You can see a number of production projects using this approach. Aave, for example, uses Chainlink Mocks to run their tests.

Using Helpers To Deploy
The most sophisticated tests can be found in the truffle smartcontractkit box.** **This is one of the first boxes that Chainlink engineers use to build their smart contracts. Once you have Truffle installed, you can get your own box spun up quickly by opening a new repo up, then running:

truffle unbox smartcontractkit/box

Once you get this up, you’ll see the MyContract_test.js which runs through all the potential scenarios you want to cover when making a Chainlink API call. Check it out in the Chainlink Truffle repo.

Summary
Testing Chainlink smart contracts is a great way to make sure your code stays high quality while you develop, and the range of options above make testing easier than ever. Don’t assume that it’s too difficult to run complicated objects with one another in a test. Integration tests are critical when it comes to scaling your dApp and building something amazing.

For those looking to get started building with all these amazing tools, be sure to hit the links in the examples, or just head over to the Chainlink documentation. You’ll find everything you need to get started and become a Solidity and blockchain engineering master.

