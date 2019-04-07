import { KeyValueStore, ChainDB } from '../../../interfaces'
import { BaseKey } from '../../common'

export class PGChainDB implements ChainDB {
  private statedb: KeyValueStore
  private historydb: KeyValueStore

  constructor(private db: KeyValueStore) {
    const statePrefix = new BaseKey('s')
    this.statedb = db.bucket(statePrefix.encode())

    const historyPrefix = new BaseKey('h')
    this.historydb = db.bucket(historyPrefix.encode())
  }
}
