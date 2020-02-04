import '../setup'
/* External Imports */
import { getLogger } from '@pigi/core-utils'
import { DB, newInMemoryDB } from '@pigi/core-db/'

/* Internal Imports */
import {
  FullnodeRpcServer,
  deployOvmContract,
  DefaultWeb3Handler,
} from '../../src/app'
import * as SimpleStorage from '../contracts/build/SimpleStorage.json'
import { ethers } from 'ethers'
import { getWallets } from 'ethereum-waffle'
import { FullnodeHandler } from '../../src/types'

const log = getLogger('ethnode-proxy', true)

const host = '0.0.0.0'
const port = 9999

/*********
 * TESTS *
 *********/

describe('Web3Handler', () => {
  let fullnodeHandler: FullnodeHandler
  let fullnodeRpcServer: FullnodeRpcServer
  let baseUrl: string

  beforeEach(async () => {
    fullnodeHandler = await DefaultWeb3Handler.create()
    fullnodeRpcServer = new FullnodeRpcServer(fullnodeHandler, host, port)

    fullnodeRpcServer.listen()

    baseUrl = `http://${host}:${port}`
  })

  afterEach(() => {
    if (!!fullnodeRpcServer) {
      fullnodeRpcServer.close()
    }
  })

  describe('SimpleStorage integration test', () => {
    it('should set storage & retrieve the value', async () => {
      const httpProvider = new ethers.providers.JsonRpcProvider(baseUrl)
      const executionManagerAddress = await httpProvider.send(
        'ovm_getExecutionManagerAddress',
        []
      )
      const wallet = getWallets(httpProvider)[0]
      const simpleStorage = await deployOvmContract(wallet, SimpleStorage)
      // Create some constants we will use for storage
      const storageKey = '0x' + '01'.repeat(32)
      const storageValue = '0x' + '02'.repeat(32)
      // Set storage with our new storage elements
      const tx = await simpleStorage.setStorage(
        executionManagerAddress,
        storageKey,
        storageValue
      )
      // Get the storage
      const receipt = await httpProvider.getTransactionReceipt(tx.hash)
      const res = await simpleStorage.getStorage(
        executionManagerAddress,
        storageKey
      )
      // Verify we got the value!
      res.should.equal(storageValue)
    })
  })
})