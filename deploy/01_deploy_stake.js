const fs = require("fs")
const path = require("path")

module.exports = async ({ getNamedAccounts, deployments, ethers, upgrades }) => {
    const { save } = deployments
    const { deployer } = await getNamedAccounts()
    // 打印部署者地址
    console.log("deployer's account:", deployer)

    // 首先部署ERC20合约
    const metaNodeFac = await ethers.getContractFactory("MetaNode")
    const metaNode = await metaNodeFac.deploy(1000000)
    await metaNode.waitForDeployment()
    const metaNodeAddress = await metaNode.getAddress()
    console.log("MetaNode deployed to:", metaNodeAddress)

    // 然后部署质押合约
    const metaNodeStakeFac = await ethers.getContractFactory("MetaNodeStake")
    // 通过UUPS代理部署合约（因为合约内部实现了_authorizeUpgrade方法）
    const metaNodeStake = await upgrades.deployProxy(
        metaNodeStakeFac,
        [metaNodeAddress, 8917592, 8924792, 100],
        { initializer: 'initialize' })
    await metaNodeStake.waitForDeployment()
    const metaNodeStakeAddress = await metaNodeStake.getAddress()
    console.log("MetaNodeStake proxy address:", metaNodeStakeAddress)
    // 获取实际的合约地址
    const metaNodeStakeImplAddress = await upgrades.erc1967.getImplementationAddress(metaNodeStakeAddress)
    console.log("MetaNodeStake implementation address:", metaNodeStakeImplAddress)

    // 保存合约地址
    const storePath = path.resolve(__dirname, "./cache/metaNodeStakeV1.json")
    fs.writeFileSync(storePath, JSON.stringify({
        metaNodeStakeAddress,
        metaNodeStakeImplAddress,
        abi: metaNodeStakeFac.interface.format(ethers.FormatTypes.json)
    }))

    await save("MetaNodeStakeV1", {
        address: metaNodeStakeAddress,
        impl: metaNodeStakeImplAddress,
    })
}

module.exports.tags = ["MetaNodeStakeV1"]