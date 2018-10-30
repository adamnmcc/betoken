// Generated by CoffeeScript 2.3.0
(function() {
  var KYBER_ADDR, NEW_TOKENS, TOKEN_FACTORY_ADDR, TestToken, TestTokenFactory, tokenFactory;

  TestTokenFactory = artifacts.require("TestTokenFactory");

  TestToken = artifacts.require("TestToken");

  KYBER_ADDR = "0x97e3bA6cC43b2aF2241d4CAD4520DA8266170988";

  TOKEN_FACTORY_ADDR = "0x76fc4b929325D04f5e3F3724eFDDFB45B52d3160";

  tokenFactory = TestTokenFactory.at(TOKEN_FACTORY_ADDR);

  NEW_TOKENS = ["DAT", "QKC", "REN", "ZRX", "REP", "BNB", "MOT"];

  module.exports = async function(callback) {
    var i, len, results, token, tokenAddr, tokenSymbol;
    results = [];
    for (i = 0, len = NEW_TOKENS.length; i < len; i++) {
      tokenSymbol = NEW_TOKENS[i];
      tokenAddr = ((await tokenFactory.newToken(tokenSymbol, tokenSymbol, 18))).logs[0].args.addr;
      token = TestToken.at(tokenAddr);
      await token.mint(KYBER_ADDR, 1e12 * 1e18);
      results.push((await token.finishMinting()));
    }
    return results;
  };

}).call(this);
