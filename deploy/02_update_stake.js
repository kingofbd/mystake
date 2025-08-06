module.exports = async ({ getNamedAccounts, deployments, ethers, upgrades }) => {
    const { save } = deployments
    const { deployer } = await getNamedAccounts()
    // 打印部署者地址
    console.log("deployer's account:", deployer)

    // 读取cache中存储的旧版本的代理合约地址
    const cachePath = path.resolve(__dirname, "./cache/metaNodeStakeV1.json")
    const cache = JSON.parse(fs.readFileSync(cachePath, "utf-8"))
    const metaNodeStakeAddress = cache.metaNodeStakeAddress
    const metaNodeStakeImplAddress = cache.metaNodeStakeImplAddress

    // 升级合约
    const metaNodeStakeFac = await ethers.getContractFactory("MetaNodeStakeV2")
    const metaNodeStake = await upgrades.upgradeProxy(metaNodeStakeAddress, metaNodeStakeFac)
    await metaNodeStake.waitForDeployment()
    const metaNodeStakeAddressV2 = await metaNodeStake.getAddress()
    console.log("MetaNodeStake upgraded to:", metaNodeStakeAddressV2)
    // 获取实际的合约地址
    const metaNodeStakeImplAddressV2 = await upgrades.erc1967.getImplementationAddress(metaNodeStakeAddressV2)
    console.log("MetaNodeStake implementation address:", metaNodeStakeImplAddressV2)

    // 保存合约地址
    const storePath = path.resolve(__dirname, "./cache/metaNodeStakeV2.json")
    fs.writeFileSync(storePath, JSON.stringify({
        metaNodeStakeAddress: metaNodeStakeAddressV2,
        metaNodeStakeImplAddress: metaNodeStakeImplAddressV2,
        abi: metaNodeStakeFac.interface.format(ethers.FormatTypes.json)
    }))

    await save("MetaNodeStakeV2", {
        address: metaNodeStakeAddressV2,
        impl: metaNodeStakeImplAddressV2,
    })
}

module.exports.tags = ["MetaNodeStakeV2"]