/**
 * 日程/课表卡片 —— 生命周期入口
 *
 * 依据 API 23 官方定义：
 *   onAddForm(want): formBindingData.FormBindingData   ← 同步返回，不能 await
 *   onUpdateForm / onFormEvent / onRemoveForm / onAcquireFormState / onSizeChanged
 *   formId 取 want.parameters[formInfo.FormParam.IDENTITY_KEY]
 *
 * 进程约束：生命周期调度完成后最多存活 10 秒，因此这里只做同步读 + 纯计算。
 */
import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { Configuration, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CardDataReader } from '../model/ScheduleStore';
import { CourseReader } from '../model/CourseStore';
import { calcNextClass, CourseTable, NextClass } from '../model/Course';
import { buildCardData } from '../model/CardData';
import { ScheduleSnapshot } from '../model/Schedule';

const TAG: string = 'EntryFormAbility';
const DOMAIN: number = 0xFF00;

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    const formId: string =
      want.parameters?.[formInfo.FormParam.IDENTITY_KEY] as string ?? '';
    const dimension: number =
      want.parameters?.[formInfo.FormParam.DIMENSION_KEY] as number ?? 0;
    hilog.info(DOMAIN, TAG, 'onAddForm formId=%{public}s dim=%{public}d', formId, dimension);
    return formBindingData.createFormBindingData(this.cardPayload());
  }

  /** 定时/定点刷新：系统回调进来，需自行 updateForm */
  onUpdateForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onUpdateForm formId=%{public}s', formId);
    this.push(formId, this.cardPayload());
  }

  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN, TAG, 'onFormEvent formId=%{public}s msg=%{public}s', formId, message);
  }

  onRemoveForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onRemoveForm formId=%{public}s', formId);
  }

  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  onConfigurationUpdate(config: Configuration): void {
    hilog.info(DOMAIN, TAG, 'onConfigurationUpdate');
  }

  onSizeChanged(formId: string, newDimension: formInfo.FormDimension, newRect: formInfo.Rect): void {
    hilog.info(DOMAIN, TAG, 'onSizeChanged formId=%{public}s dim=%{public}d', formId, newDimension);
  }

  /** 卡片进程统一取数：日程快照 + 下一节课（全同步，不 await） */
  private cardPayload(): Record<string, string> {
    const now: number = Date.now();
    const snap: ScheduleSnapshot = CardDataReader.readSnapshot(this.context, now);
    const table: CourseTable = CourseReader.readSync(this.context);
    const next: NextClass = calcNextClass(table, now);
    return buildCardData(snap, next);
  }

  private push(formId: string, payload: Record<string, string>): void {
    const data: formBindingData.FormBindingData = formBindingData.createFormBindingData(payload);
    formProvider.updateForm(formId, data).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'updateForm failed: %{public}s', JSON.stringify(err));
    });
  }
}