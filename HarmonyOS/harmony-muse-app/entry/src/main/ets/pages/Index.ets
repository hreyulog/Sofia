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

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text('Sofia Harmony Muse')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .width('100%')

        Text(this.role === 'PRIMARY'
          ? '把任务交给备用手机，它会在后台替你处理'
          : '这台备用手机正在作为你的专属 AI 执行环境')
          .fontSize(15)
          .fontColor('#666666')
          .width('100%')

        Row() {
          Column({ space: 4 }) {
            Text(this.role)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
            Text(this.deviceModel)
              .fontSize(13)
              .fontColor('#666666')
          }
          .alignItems(HorizontalAlign.Start)

          Blank()

          Column({ space: 4 }) {
            Text(this.runtimeState)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
            Text('Relay ' + this.relayState)
              .fontSize(12)
              .fontColor('#666666')
          }
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .padding(16)
        .backgroundColor('#F3F5F7')
        .borderRadius(18)

        if (this.role === 'PRIMARY') {
          Column({ space: 12 }) {
            Text('What should I do for you?')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .width('100%')

            TextInput({
              text: this.goal,
              placeholder: '交代一个任务...'
            })
              .height(54)
              .width('100%')
              .onChange((value: string) => {
                this.goal = value;
              })

            Button('交给备用机')
              .height(52)
              .width('100%')
              .onClick(() => {
                this.submitTask();
              })
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#EEF7FF')
          .borderRadius(18)
        }

        Column({ space: 8 }) {
          Text('Task')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .width('100%')

          Text(this.taskPhase)
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .width('100%')

          Text(this.currentTaskId)
            .fontSize(12)
            .fontColor('#777777')
            .width('100%')

          if (this.currentGoal.length > 0) {
            Text(this.currentGoal)
              .fontSize(14)
              .fontColor('#444444')
              .width('100%')
          }

          Text(this.activityText)
            .fontSize(14)
            .fontColor('#666666')
            .width('100%')
        }
        .width('100%')
        .padding(18)
        .backgroundColor('#F8F8F8')
        .borderRadius(18)

        if (this.resultText.length > 0) {
          Column({ space: 8 }) {
            Text('Result')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .width('100%')

            if (this.resultModel.length > 0) {
              Text(this.resultModel)
                .fontSize(12)
                .fontColor('#777777')
                .width('100%')
            }

            Text(this.resultText)
              .fontSize(15)
              .width('100%')
          }
          .width('100%')
          .padding(18)
          .backgroundColor('#F3FFF5')
          .borderRadius(18)
        }
      }
      .padding(22)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }
}
