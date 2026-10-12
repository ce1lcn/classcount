import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import {
  WordList, WordbookLists, WordbookRecords, WordSession,
  decodeLists, decodeRecords, decodeSession
} from './Wordbook';

const STORE_NAME: string = 'wordbook_store_v1';
const K_LISTS: string = 'wordbook_lists';
const K_RECORDS: string = 'wordbook_records';
const K_SESSION: string = 'wordbook_session';

export class WordbookData {
  lists: WordList[] = [];
  records: WordbookRecords = new WordbookRecords();
  session: WordSession = new WordSession();
}

/**
 * 背单词持久化：独立存储文件，不接触日程、课表与卡片数据。
 * 错误一律以 Error 抛给页面显示，绝不静默吞掉，也绝不在读取失败后用空数据覆盖原数据。
 * 同时改动多个键时（例如记录 + 会话）一次 put 后统一 flush，失败则还原。
 */
export class WordbookStore {
  private context: common.Context;
  private pref: preferences.Preferences | null = null;

  constructor(context: common.Context) {
    this.context = context;
  }

  private async open(): Promise<preferences.Preferences> {
    try {
      if (this.pref === null) {
        this.pref = await preferences.getPreferences(this.context, STORE_NAME);
      }
      return this.pref;
    } catch (err) {
      throw new Error('无法打开词表存储');
    }
  }

  async load(): Promise<WordbookData> {
    const pref: preferences.Preferences = await this.open();
    const data: WordbookData = new WordbookData();
    let rawLists: string = '';
    let rawRecords: string = '';
    let rawSession: string = '';
    try {
      rawLists = await pref.get(K_LISTS, '') as string;
      rawRecords = await pref.get(K_RECORDS, '') as string;
      rawSession = await pref.get(K_SESSION, '') as string;
    } catch (err) {
      throw new Error('无法读取词表，原数据已保留');
    }
    if (rawLists.length > 0) {
      data.lists = decodeLists(rawLists).lists;
    }
    if (rawRecords.length > 0) {
      data.records = decodeRecords(rawRecords);
    }
    if (rawSession.length > 0) {
      data.session = decodeSession(rawSession);
    }
    return data;
  }

  /** 先写后读校验，再整体落盘；任一步失败都还原已写入的键 */
  private async write(keys: string[], values: string[]): Promise<void> {
    const pref: preferences.Preferences = await this.open();
    const previous: string[] = [];
    try {
      for (let i: number = 0; i < keys.length; i++) {
        previous.push(await pref.get(keys[i], '') as string);
      }
    } catch (err) {
      throw new Error('无法读取原数据，已取消保存');
    }
    try {
      for (let i: number = 0; i < keys.length; i++) {
        await pref.put(keys[i], values[i]);
      }
      await pref.flush();
    } catch (err) {
      try {
        for (let i: number = 0; i < keys.length; i++) {
          await pref.put(keys[i], previous[i]);
        }
        await pref.flush();
      } catch (restoreError) {
        throw new Error('存储不可用，请重试');
      }
      throw new Error('保存失败，请重试');
    }
  }

  private encodeLists(lists: WordList[]): string {
    const wrapper: WordbookLists = new WordbookLists();
    wrapper.lists = lists;
    const raw: string = JSON.stringify(wrapper);
    decodeLists(raw);
    return raw;
  }

  private encodeRecords(records: WordbookRecords): string {
    const raw: string = JSON.stringify(records);
    decodeRecords(raw);
    return raw;
  }

  /** 没有会话（listName 为空）时写入空串 */
  private encodeSession(session: WordSession): string {
    if (session.listName.length === 0) {
      return '';
    }
    const raw: string = JSON.stringify(session);
    decodeSession(raw);
    return raw;
  }

  async saveSession(session: WordSession): Promise<void> {
    await this.write([K_SESSION], [this.encodeSession(session)]);
  }

  async saveRecordsAndSession(records: WordbookRecords, session: WordSession): Promise<void> {
    await this.write([K_RECORDS, K_SESSION], [this.encodeRecords(records), this.encodeSession(session)]);
  }

  /** 导入 / 删除词表：词表、记录、会话三者同时落盘 */
  async saveAll(lists: WordList[], records: WordbookRecords, session: WordSession): Promise<void> {
    await this.write([K_LISTS, K_RECORDS, K_SESSION],
      [this.encodeLists(lists), this.encodeRecords(records), this.encodeSession(session)]);
  }
}
