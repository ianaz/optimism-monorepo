import { HistoryManager, ChainDB } from '../../../interfaces'
import { Process } from '../../common'
import { PGHistoryManager } from './history-manager'

export class PGHistoryManagerProcoess extends Process<HistoryManager> {
  constructor(private chaindb: Process<ChainDB>) {
    super()
  }

  protected async onStart(): Promise<void> {
    await this.chaindb.waitUntilStarted()

    const chaindb = this.chaindb.subject
    this.subject = new PGHistoryManager(chaindb)
  }
}
