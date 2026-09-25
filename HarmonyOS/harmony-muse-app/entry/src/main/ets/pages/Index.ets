import http from '@ohos.net.http';
import deviceInfo from '@ohos.deviceInfo';

// Prototype configuration. Replace with your HTTPS relay before building the HAP.
// Do not commit credentials here; the relay is a transport only.
const RELAY_BASE: string = 'https://replace-with-your-relay.example.com';

interface RelayMessage {
  id: string;
  from: string;
  to: string;
  type: string;
  payload: string | null;
  ts: number;
}

interface PollResponse {
  ok: boolean;
  message: RelayMessage | null;
}

interface SendResponse {
  ok: boolean;
  accepted: string;
}

interface TaskPayload {
  goal: string;
  createdAt: number;
}

interface ProgressPayload {
  phase: string;
  detail: string;
}

interface ResultPayload {
  summary: string;
  model: string;
}

interface PlannerResponse {
  ok: boolean;
  taskId?: string;
  model?: string;
  content?: string;
  error?: string;
}

@Entry
@Component
struct Index {
  @State role: string = 'UNASSIGNED';
  @State deviceModel: string = 'unknown';
  @State relayState: string = 'CHECKING';
  @State runtimeState: string = 'STARTING';

  @State goal: string = '比较淘宝、天猫、京东上的华为 Mate 80，优先官方旗舰店或京东自营，给出价格、补贴到手价和简短购买建议。';
  @State currentGoal: string = '';
  @State taskPhase: string = 'READY';
  @State currentTaskId: string = '-';
  @State resultText: string = '';
  @State resultModel: string = '';
  @State activityText: string = 'Runtime starting...';

  private pollTimer: number = -1;
  private pollBusy: boolean = false;

  aboutToAppear(): void {
    this.deviceModel = deviceInfo.productModel;
    if (this.deviceModel === 'KLE-AL00U') {
      this.role = 'EXECUTOR';
    } else if (this.deviceModel === 'BRA-AL00') {
      this.role = 'PRIMARY';
    } else {
      this.role = 'PRIMARY';
    }
    this.startRuntime();
  }

  aboutToDisappear(): void {
    if (this.pollTimer >= 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private setActivity(text: string): void {
    this.activityText = text;
  }

  private responseText(result: http.HttpResponse): string {
    if (typeof result.result === 'string') {
      return result.result;
    }
    return JSON.stringify(result.result);
  }

  private async checkRelay(): Promise<void> {
    const req = http.createHttp();
    try {
      const result = await req.request(RELAY_BASE + '/health', {
        method: http.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: 10000
      });
      this.relayState = result.responseCode === 200 ? 'ONLINE' : 'HTTP ' + result.responseCode.toString();
    } catch (err) {
      this.relayState = 'OFFLINE';
      this.runtimeState = 'OFFLINE';
      this.setActivity('Relay connection failed');
    } finally {
      req.destroy();
    }
  }

  private async postMessage(to: string, type: string, payload: string, id: string): Promise<boolean> {
    const req = http.createHttp();
    try {
      const requestBody: string = JSON.stringify({
        id: id,
        from: this.role.toLowerCase(),
        to: to,
        type: type,
        payload: payload
      });

      const result = await req.request(RELAY_BASE + '/send', {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json'
        },
        extraData: requestBody,
        connectTimeout: 10000,
        readTimeout: 10000
      });

      const parsed: SendResponse = JSON.parse(this.responseText(result)) as SendResponse;
      return parsed.ok;
    } catch (err) {
      this.runtimeState = 'SEND ERROR';
      this.setActivity('Send failed: ' + JSON.stringify(err));
      return false;
    } finally {
      req.destroy();
    }
  }

  private async pollRole(role: string): Promise<RelayMessage | null> {
    const req = http.createHttp();
    try {
      const result = await req.request(RELAY_BASE + '/poll?role=' + role, {
        method: http.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: 10000
      });
      const parsed: PollResponse = JSON.parse(this.responseText(result)) as PollResponse;
      if (parsed.ok) {
        return parsed.message;
      }
      return null;
    } catch (err) {
      this.runtimeState = 'POLL ERROR';
      this.setActivity('Poll failed: ' + JSON.stringify(err));
      return null;
    } finally {
      req.destroy();
    }
  }

  private async callPlanner(goalText: string, taskId: string): Promise<PlannerResponse | null> {
    const req = http.createHttp();
    try {
      const body: string = JSON.stringify({
        goal: goalText,
        taskId: taskId
      });

      const result = await req.request(RELAY_BASE + '/llm', {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json'
        },
        extraData: body,
        connectTimeout: 10000,
        readTimeout: 120000
      });

      const parsed: PlannerResponse = JSON.parse(this.responseText(result)) as PlannerResponse;
      return parsed;
    } catch (err) {
      this.setActivity('MiniMax request failed: ' + JSON.stringify(err));
      return null;
    } finally {
      req.destroy();
    }
  }

  private async startRuntime(): Promise<void> {
    await this.checkRelay();
    if (this.relayState !== 'ONLINE') {
      return;
    }

    this.runtimeState = 'RUNNING';

    if (this.role === 'PRIMARY') {
      this.setActivity('Primary console ready');
    } else {
      this.setActivity('Spare-phone executor ready');
    }

    this.pollTimer = setInterval(() => {
      this.pollNow();
    }, 1200);

  }

  private async submitTask(): Promise<void> {
    if (this.role !== 'PRIMARY') {
      return;
    }

    const trimmed: string = this.goal.trim();
    if (trimmed.length === 0) {
      this.setActivity('Please enter a task');
      return;
    }

    const id: string = 'task-' + Date.now().toString();
    const payload: TaskPayload = {
      goal: trimmed,
      createdAt: Date.now()
    };

    this.currentTaskId = id;
    this.currentGoal = trimmed;
    this.taskPhase = 'SUBMITTING';
    this.resultText = '';
    this.resultModel = '';
    this.setActivity('Sending task to spare phone...');

    const ok: boolean = await this.postMessage(
      'executor',
      'TASK_REQUEST',
      JSON.stringify(payload),
      id
    );

    if (ok) {
      this.taskPhase = 'SUBMITTED';
      this.setActivity('Task submitted. Spare phone will continue in background.');
    }
  }

  private async sendProgress(taskId: string, phase: string, detail: string): Promise<void> {
    const payload: ProgressPayload = {
      phase: phase,
      detail: detail
    };
    await this.postMessage('primary', 'TASK_PROGRESS', JSON.stringify(payload), taskId);
  }

  private async executeTask(msg: RelayMessage): Promise<void> {
    let payload: TaskPayload;
    try {
      payload = JSON.parse(msg.payload === null ? '{}' : msg.payload) as TaskPayload;
    } catch (err) {
      return;
    }

    this.currentTaskId = msg.id;
    this.currentGoal = payload.goal;
    this.taskPhase = 'ACCEPTED';
    this.resultText = '';
    this.resultModel = '';
    this.setActivity('Accepted task from primary');

    await this.postMessage(
      'primary',
      'TASK_ACCEPTED',
      JSON.stringify({
        phase: 'ACCEPTED',
        detail: 'Spare phone accepted the task'
      }),
      msg.id
    );

    this.taskPhase = 'WORKING';
    this.setActivity('Running agent skill on spare phone...');
    await this.sendProgress(msg.id, 'WORKING', 'Spare phone is searching Taobao, Tmall and JD');

    const plan: PlannerResponse | null = await this.callPlanner(payload.goal, msg.id);

    if (plan === null || !plan.ok || !plan.content) {
      this.taskPhase = 'FAILED';
      this.setActivity('Agent task failed');
      await this.postMessage(
        'primary',
        'TASK_FAILED',
        JSON.stringify({
          phase: 'FAILED',
          detail: plan === null ? 'No planner response' : String(plan.error || 'Planner failed')
        }),
        msg.id
      );
      return;
    }

    this.resultText = plan.content;
    this.resultModel = String(plan.model || 'MiniMax-M3');
    this.taskPhase = 'COMPLETED';
    this.setActivity('Shopping comparison ready; returning to primary');

    const result: ResultPayload = {
      summary: this.resultText,
      model: this.resultModel
    };

    await this.postMessage(
      'primary',
      'TASK_COMPLETED',
      JSON.stringify(result),
      msg.id
    );
  }

  private handlePrimaryMessage(msg: RelayMessage): void {
    this.currentTaskId = msg.id;

    if (msg.type === 'TASK_ACCEPTED') {
      this.taskPhase = 'ACCEPTED';
      this.setActivity('Spare phone accepted the task');
      return;
    }

    if (msg.type === 'TASK_PROGRESS') {
      try {
        const progress: ProgressPayload = JSON.parse(msg.payload === null ? '{}' : msg.payload) as ProgressPayload;
        this.taskPhase = progress.phase;
        this.setActivity(progress.detail);
      } catch (err) {
        this.taskPhase = 'WORKING';
      }
      return;
    }

    if (msg.type === 'TASK_COMPLETED') {
      try {
        const result: ResultPayload = JSON.parse(msg.payload === null ? '{}' : msg.payload) as ResultPayload;
        this.resultText = result.summary;
        this.resultModel = result.model;
      } catch (err) {
        this.resultText = 'Task completed';
        this.resultModel = '';
      }
      this.taskPhase = 'COMPLETED';
      this.setActivity('Result received from spare phone');
      return;
    }

    if (msg.type === 'TASK_FAILED') {
      try {
        const progress: ProgressPayload = JSON.parse(msg.payload === null ? '{}' : msg.payload) as ProgressPayload;
        this.setActivity(progress.detail);
      } catch (err) {
        this.setActivity('Task failed on spare phone');
      }
      this.taskPhase = 'FAILED';
    }
  }

  private async pollNow(): Promise<void> {
    if (this.pollBusy || this.relayState !== 'ONLINE') {
      return;
    }

    this.pollBusy = true;
    try {
      const msg: RelayMessage | null = await this.pollRole(this.role.toLowerCase());
      if (msg === null) {
        return;
      }

      if (this.role === 'PRIMARY') {
        this.handlePrimaryMessage(msg);
        return;
      }

      if (msg.type === 'TASK_REQUEST') {
        await this.executeTask(msg);
      }
    } finally {
      this.pollBusy = false;
    }
  }

  private phaseTitle(): string {
    if (this.taskPhase === 'SUBMITTED') {
      return '已发送到备用机';
    }
    if (this.taskPhase === 'ACCEPTED') {
      return '备用机已接单';
    }
    if (this.taskPhase === 'WORKING') {
      return '正在执行';
    }
    if (this.taskPhase === 'COMPLETED') {
      return '任务已完成';
    }
    if (this.taskPhase === 'FAILED') {
      return '任务失败';
    }
    if (this.taskPhase === 'SUBMITTING') {
      return '正在发送';
    }
    return '等待任务';
  }

  private phaseMark(): string {
    if (this.taskPhase === 'COMPLETED') {
      return '✓';
    }
    if (this.taskPhase === 'FAILED') {
      return '!';
    }
    if (this.taskPhase === 'WORKING' || this.taskPhase === 'ACCEPTED' ||
      this.taskPhase === 'SUBMITTED' || this.taskPhase === 'SUBMITTING') {
      return '●';
    }
    return '○';
  }

  private roleTitle(): string {
    return this.role === 'PRIMARY' ? '主手机' : '执行手机';
  }

  private connectionText(): string {
    if (this.relayState === 'ONLINE' && this.runtimeState === 'RUNNING') {
      return '已连接';
    }
    if (this.relayState === 'CHECKING') {
      return '连接中';
    }
    return '连接异常';
  }

  build() {
    Column() {
      // Sofia-style top app bar. The Android/Compose UI remains untouched;
      // this is the HarmonyOS ArkUI adaptation.
      Row() {
        Column({ space: 2 }) {
          Text('Sofia')
            .fontSize(23)
            .fontWeight(FontWeight.Bold)
            .fontColor('#15171A')
          Text('Harmony Muse')
            .fontSize(12)
            .fontColor('#777C84')
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        Row({ space: 7 }) {
          Text('●')
            .fontSize(10)
            .fontColor(this.relayState === 'ONLINE' ? '#28A36A' : '#D65C5C')
          Text(this.connectionText())
            .fontSize(13)
            .fontColor('#50545B')
        }
        .padding({ left: 11, right: 11, top: 7, bottom: 7 })
        .backgroundColor('#F1F2F4')
        .borderRadius(18)

        Text('⋮')
          .fontSize(24)
          .fontColor('#4B4F56')
          .margin({ left: 14 })
      }
      .height(76)
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 4 })
      .backgroundColor('#FFFFFF')

      Scroll() {
        Column({ space: 14 }) {
          // Connected-device card: a compact equivalent of Sofia's runtime status area.
          Row() {
            Column({ space: 5 }) {
              Row({ space: 8 }) {
                Text(this.role === 'PRIMARY' ? '◉' : '◆')
                  .fontSize(17)
                  .fontColor('#26282C')
                Text(this.roleTitle())
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#202226')
              }
              Text(this.deviceModel)
                .fontSize(12)
                .fontColor('#7A7F87')
            }
            .alignItems(HorizontalAlign.Start)

            Blank()

            Column({ space: 4 }) {
              Text(this.role === 'PRIMARY' ? 'Nova 执行机' : '等待主手机任务')
                .fontSize(13)
                .fontColor('#4F545B')
              Text(this.runtimeState + ' · Relay ' + this.relayState)
                .fontSize(11)
                .fontColor('#8B9097')
            }
            .alignItems(HorizontalAlign.End)
          }
          .width('100%')
          .padding(15)
          .backgroundColor('#FFFFFF')
          .borderRadius(16)

          if (this.role === 'PRIMARY') {
            // Assistant intro bubble.
            Row() {
              Column({ space: 5 }) {
                Text('S')
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
              }
              .width(30)
              .height(30)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .backgroundColor('#202226')
              .borderRadius(15)

              Column({ space: 5 }) {
                Text('Sofia')
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#60656D')
                Text('把目标告诉我。我会把任务交给你的备用手机持续执行，完成后把结果带回来。')
                  .fontSize(15)
                  .fontColor('#25282D')
                  .lineHeight(22)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 10 })
            }
            .width('100%')
            .padding(14)
            .backgroundColor('#FFFFFF')
            .borderRadius(16)

            if (this.currentGoal.length > 0) {
              Row() {
                Blank()
                Column({ space: 5 }) {
                  Text('你')
                    .fontSize(11)
                    .fontColor('#80858C')
                  Text(this.currentGoal)
                    .fontSize(15)
                    .fontColor('#FFFFFF')
                    .lineHeight(22)
                }
                .alignItems(HorizontalAlign.Start)
                .padding(14)
                .constraintSize({ maxWidth: '84%' })
                .backgroundColor('#25272B')
                .borderRadius(16)
              }
              .width('100%')
            }
          }

          // Task card shared by both roles.
          Column({ space: 10 }) {
            Row() {
              Row({ space: 9 }) {
                Text(this.phaseMark())
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.taskPhase === 'FAILED' ? '#C44949' :
                    (this.taskPhase === 'COMPLETED' ? '#25875A' : '#555A61'))
                Column({ space: 2 }) {
                  Text(this.phaseTitle())
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#25282D')
                  Text(this.activityText)
                    .fontSize(12)
                    .fontColor('#747A82')
                }
                .alignItems(HorizontalAlign.Start)
              }
              Blank()
              if (this.currentTaskId !== '-') {
                Text('任务')
                  .fontSize(11)
                  .fontColor('#8A8F96')
                  .padding({ left: 9, right: 9, top: 5, bottom: 5 })
                  .backgroundColor('#F1F2F4')
                  .borderRadius(12)
              }
            }
            .width('100%')

            if (this.currentTaskId !== '-') {
              Text(this.currentTaskId)
                .fontSize(10)
                .fontColor('#9A9EA4')
                .width('100%')
            }

            if (this.role === 'EXECUTOR' && this.currentGoal.length > 0) {
              Text(this.currentGoal)
                .fontSize(14)
                .fontColor('#4B5057')
                .lineHeight(20)
                .width('100%')
            }

            if (this.taskPhase === 'WORKING') {
              Row({ space: 8 }) {
                Text('淘宝')
                  .fontSize(11)
                  .fontColor('#656A72')
                  .padding({ left: 9, right: 9, top: 5, bottom: 5 })
                  .backgroundColor('#F3F4F5')
                  .borderRadius(11)
                Text('天猫')
                  .fontSize(11)
                  .fontColor('#656A72')
                  .padding({ left: 9, right: 9, top: 5, bottom: 5 })
                  .backgroundColor('#F3F4F5')
                  .borderRadius(11)
                Text('京东')
                  .fontSize(11)
                  .fontColor('#656A72')
                  .padding({ left: 9, right: 9, top: 5, bottom: 5 })
                  .backgroundColor('#F3F4F5')
                  .borderRadius(11)
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(16)

          if (this.resultText.length > 0) {
            Row() {
              Column() {
                Text('S')
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF')
              }
              .width(30)
              .height(30)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .backgroundColor('#202226')
              .borderRadius(15)

              Column({ space: 8 }) {
                Row() {
                  Text('任务结果')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#303339')
                  Blank()
                  if (this.resultModel.length > 0) {
                    Text(this.resultModel)
                      .fontSize(10)
                      .fontColor('#858A91')
                  }
                }
                .width('100%')

                Text(this.resultText)
                  .fontSize(14)
                  .fontColor('#30343A')
                  .lineHeight(21)
                  .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 10 })
            }
            .width('100%')
            .padding(15)
            .backgroundColor('#FFFFFF')
            .borderRadius(16)
          }

          if (this.role === 'EXECUTOR') {
            Column({ space: 7 }) {
              Text('执行机模式')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor('#4D5259')
              Text('这台手机会在收到任务后打开真实 App、运行 Skill，并把进度和结果同步回主手机。')
                .fontSize(13)
                .fontColor('#777C84')
                .lineHeight(19)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(15)
            .backgroundColor('#ECEEF1')
            .borderRadius(16)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 18 })
      }
      .layoutWeight(1)
      .width('100%')
      .backgroundColor('#F6F7F8')

      if (this.role === 'PRIMARY') {
        Column({ space: 9 }) {
          Row({ space: 9 }) {
            TextInput({
              text: this.goal,
              placeholder: '给 Sofia 一个任务…'
            })
              .height(50)
              .layoutWeight(1)
              .backgroundColor('#F3F4F5')
              .borderRadius(14)
              .fontSize(14)
              .onChange((value: string) => {
                this.goal = value;
              })

            Button('发送')
              .height(50)
              .width(76)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .backgroundColor('#25272B')
              .borderRadius(14)
              .onClick(() => {
                this.submitTask();
              })
          }
          .width('100%')

          Text('任务将在备用手机上继续运行 · 敏感操作需要单独确认')
            .fontSize(10)
            .fontColor('#9A9EA4')
            .width('100%')
        }
        .padding({ left: 16, right: 16, top: 11, bottom: 13 })
        .backgroundColor('#FFFFFF')
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F6F7F8')
  }
}
