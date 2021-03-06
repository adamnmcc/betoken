// Generated by CoffeeScript 2.3.2
(function() {
  var BetokenFund, BetokenLogic, BetokenProxy, BigNumber, CompoundOrderFactory, ETH_ADDR, LongOrderLogic, MiniMeToken, MiniMeTokenFactory, PRECISION, ShortOrderLogic, WETH_ADDR, ZERO_ADDR, bnToString;

  BetokenFund = artifacts.require("BetokenFund");

  BetokenProxy = artifacts.require("BetokenProxy");

  MiniMeToken = artifacts.require("MiniMeToken");

  MiniMeTokenFactory = artifacts.require("MiniMeTokenFactory");

  LongOrderLogic = artifacts.require("LongOrderLogic");

  ShortOrderLogic = artifacts.require("ShortOrderLogic");

  CompoundOrderFactory = artifacts.require("CompoundOrderFactory");

  BetokenLogic = artifacts.require("BetokenLogic");

  BigNumber = require("bignumber.js");

  ZERO_ADDR = "0x0000000000000000000000000000000000000000";

  ETH_ADDR = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";

  WETH_ADDR = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";

  PRECISION = 1e18;

  bnToString = function(bn) {
    return BigNumber(bn).toFixed(0);
  };

  module.exports = function(deployer, network, accounts) {
    return deployer.then(async function() {
      var COMPOUND_ADDR, ControlToken, DAI_ADDR, DEVELOPER_ACCOUNT, KAIRO_ADDR, KYBER_ADDR, STABLECOINS, ShareToken, TestCompound, TestDAI, TestKyberNetwork, TestToken, TestTokenFactory, betokenFund, config, controlTokenAddr, fund, i, j, k, l, len, len1, len2, minimeFactory, ref, ref1, shareTokenAddr, testDAIAddr, testTokenFactory, token, tokenAddrs, tokenObj, tokenPrices, tokensInfo;
      switch (network) {
        case "development":
          // Local testnet migration
          config = require("../deployment_configs/testnet.json");
          TestKyberNetwork = artifacts.require("TestKyberNetwork");
          TestToken = artifacts.require("TestToken");
          TestTokenFactory = artifacts.require("TestTokenFactory");
          TestCompound = artifacts.require("TestCompound");
          // deploy TestToken factory
          await deployer.deploy(TestTokenFactory);
          testTokenFactory = (await TestTokenFactory.deployed());
          // create TestDAI
          testDAIAddr = ((await testTokenFactory.newToken("DAI Stable Coin", "DAI", 18))).logs[0].args.addr;
          TestDAI = (await TestToken.at(testDAIAddr));
          
          // mint DAI for owner
          await TestDAI.mint(accounts[0], bnToString(1e7 * PRECISION)); // ten million
          
          // create TestTokens
          tokensInfo = require("../deployment_configs/kn_tokens.json");
          tokenAddrs = [];
          for (j = 0, len = tokensInfo.length; j < len; j++) {
            token = tokensInfo[j];
            tokenAddrs.push(((await testTokenFactory.newToken(token.name, token.symbol, token.decimals))).logs[0].args.addr);
          }
          tokenAddrs.push(TestDAI.address);
          tokenAddrs.push(ETH_ADDR);
          tokenPrices = ((function() {
            var k, ref, results;
            results = [];
            for (i = k = 1, ref = tokensInfo.length; (1 <= ref ? k <= ref : k >= ref); i = 1 <= ref ? ++k : --k) {
              results.push(bnToString(1000 * PRECISION));
            }
            return results;
          })()).concat([bnToString(PRECISION), bnToString(10000 * PRECISION)]);
          
          // deploy TestKyberNetwork
          await deployer.deploy(TestKyberNetwork, tokenAddrs, tokenPrices);
          // deploy TestCompound
          await deployer.deploy(TestCompound, tokenAddrs.slice(0, +(tokenAddrs.length - 2) + 1 || 9e9).concat([WETH_ADDR]), tokenPrices);
          ref = tokenAddrs.slice(0, +(tokenAddrs.length - 2) + 1 || 9e9);
          // mint tokens for KN
          for (k = 0, len1 = ref.length; k < len1; k++) {
            token = ref[k];
            tokenObj = (await TestToken.at(token));
            await tokenObj.mint(TestKyberNetwork.address, bnToString(1e12 * PRECISION)); // one trillion tokens
          }
          ref1 = tokenAddrs.slice(0, +(tokenAddrs.length - 2) + 1 || 9e9);
          
          // mint tokens for Compound
          for (l = 0, len2 = ref1.length; l < len2; l++) {
            token = ref1[l];
            tokenObj = (await TestToken.at(token));
            await tokenObj.mint(TestCompound.address, bnToString(1e12 * PRECISION)); // one trillion tokens
          }
          
          // deploy Kairo and Betoken Shares contracts
          await deployer.deploy(MiniMeTokenFactory);
          minimeFactory = (await MiniMeTokenFactory.deployed());
          controlTokenAddr = ((await minimeFactory.createCloneToken(ZERO_ADDR, 0, "Kairo", 18, "KRO", true))).logs[0].args.addr;
          shareTokenAddr = ((await minimeFactory.createCloneToken(ZERO_ADDR, 0, "Betoken Shares", 18, "BTKS", true))).logs[0].args.addr;
          ControlToken = (await MiniMeToken.at(controlTokenAddr));
          ShareToken = (await MiniMeToken.at(shareTokenAddr));
          
          // deploy ShortOrderLogic
          await deployer.deploy(ShortOrderLogic);
          
          // deploy LongOrderLogic
          await deployer.deploy(LongOrderLogic);
          // deploy CompoundOrderFactory
          await deployer.deploy(CompoundOrderFactory, ShortOrderLogic.address, LongOrderLogic.address, TestDAI.address, TestKyberNetwork.address, TestCompound.address);
          // deploy BetokenLogic
          await deployer.deploy(BetokenLogic);
          // deploy BetokenFund contract
          await deployer.deploy(BetokenFund, ControlToken.address, ShareToken.address, accounts[0], config.phaseLengths, bnToString(config.developerFeeRate), bnToString(config.exitFeeRate), ZERO_ADDR, TestDAI.address, TestKyberNetwork.address, TestCompound.address, CompoundOrderFactory.address, BetokenLogic.address, [TestDAI.address]);
          betokenFund = (await BetokenFund.deployed());
          // deploy BetokenProxy contract
          await deployer.deploy(BetokenProxy, BetokenFund.address);
          // set proxy address in BetokenFund
          await betokenFund.setProxy(BetokenProxy.address);
          await ControlToken.transferOwnership(betokenFund.address);
          return (await ShareToken.transferOwnership(betokenFund.address));
        case "mainnet":
          // Mainnet Migration
          config = require("../deployment_configs/mainnet.json");
          PRECISION = 1e18;
          KAIRO_ADDR = "0x0532894d50c8f6D51887f89eeF853Cc720D7ffB4";
          KYBER_ADDR = "0x818E6FECD516Ecc3849DAf6845e3EC868087B755";
          DAI_ADDR = "0x89d24A6b4CcB1B6fAA2625fE562bDD9a23260359";
          COMPOUND_ADDR = "0x3FDA67f7583380E67ef93072294a7fAc882FD7E7";
          DEVELOPER_ACCOUNT = "0x332d87209f7c8296389c307eae170c2440830a47";
          STABLECOINS = [
            DAI_ADDR,
            "0x0000000000085d4780B73119b644AE5ecd22b376", // TUSD
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", // USDC
            "0xdB25f211AB05b1c97D595516F45794528a807ad8", // EURS
            "0xdAC17F958D2ee523a2206206994597C13D831ec7", // USDT
            "0x056Fd409E1d7A124BD7017459dFEa2F387b6d5Cd", // GUSD
            "0x8E870D67F660D95d5be530380D0eC0bd388289E1", // PAX
            "0x57Ab1E02fEE23774580C119740129eAC7081e9D3", // sUSD
            "0xAbdf147870235FcFC34153828c769A70B3FAe01F" // EURT
          ];
          // deploy Betoken Shares contracts
          await deployer.deploy(MiniMeTokenFactory);
          minimeFactory = (await MiniMeTokenFactory.deployed());
          ShareToken = MiniMeToken.at(((await minimeFactory.createCloneToken("0x0", 0, "Betoken Shares", 18, "BTKS", true))).logs[0].args.addr);
          // deploy ShortOrderLogic
          await deployer.deploy(ShortOrderLogic);
          
          // deploy LongOrderLogic
          await deployer.deploy(LongOrderLogic);
          // deploy CompoundOrderFactory
          await deployer.deploy(CompoundOrderFactory, ShortOrderLogic.address, LongOrderLogic.address, DAI_ADDR, KYBER_ADDR, COMPOUND_ADDR);
          // deploy BetokenLogic
          await deployer.deploy(BetokenLogic);
          // deploy BetokenFund contract
          await deployer.deploy(BetokenFund, KAIRO_ADDR, ShareToken.address, DEVELOPER_ACCOUNT, config.phaseLengths, bnToString(config.developerFeeRate), bnToString(config.exitFeeRate), ZERO_ADDR, DAI_ADDR, KYBER_ADDR, COMPOUND_ADDR, CompoundOrderFactory.address, BetokenLogic.address);
          // deploy BetokenProxy contract
          await deployer.deploy(BetokenProxy, BetokenFund.address);
          // set proxy address in BetokenFund
          await betokenFund.setProxy(BetokenProxy.address);
          // transfer ShareToken ownership to BetokenFund
          await ShareToken.transferOwnership(BetokenFund.address);
          // transfer fund ownership to developer multisig
          fund = (await BetokenFund.deployed());
          return (await fund.transferOwnership(DEVELOPER_ACCOUNT));
      }
    });
  };

  // IMPORTANT: After deployment, need to transfer ownership of Kairo contract to the BetokenFund contract

}).call(this);
