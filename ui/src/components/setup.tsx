import { Component, linkEvent } from 'inferno';
import { Subscription } from "rxjs";
import { retryWhen, delay, take } from 'rxjs/operators';
import { RegisterForm, LoginResponse, UserOperation } from '../interfaces';
import { WebSocketService, UserService } from '../services';
import { msgOp } from '../utils';
import { SiteForm } from './site-form';

interface State {
  userForm: RegisterForm;
  doneRegisteringUser: boolean;
  userLoading: boolean;
}

export class Setup extends Component<any, State> {
  private subscription: Subscription;

  private emptyState: State = {
    userForm: {
      username: undefined,
      password: undefined,
      password_verify: undefined,
      admin: true,
    },
    doneRegisteringUser: false,
    userLoading: false,
  }


  constructor(props: any, context: any) {
    super(props, context);

    this.state = this.emptyState;

    this.subscription = WebSocketService.Instance.subject
    .pipe(retryWhen(errors => errors.pipe(delay(3000), take(10))))
    .subscribe(
      (msg) => this.parseMessage(msg),
        (err) => console.error(err),
        () => console.log("complete")
    );
  }

  componentWillUnmount() {
    this.subscription.unsubscribe();
  }

  render() {
    return (
      <div class="container">
        <div class="row">
          <div class="col-12 offset-lg-3 col-lg-6">
            <h3>Lemmy Instance Setup</h3>
            {!this.state.doneRegisteringUser ? this.registerUser() : <SiteForm />}
          </div>
        </div>
      </div>
    )
  }

  registerUser() {
    return (
      <form onSubmit={linkEvent(this, this.handleRegisterSubmit)}>
        <h5>Set up Site Administrator</h5>
        <div class="form-group row">
          <label class="col-sm-2 col-form-label">Username</label>
          <div class="col-sm-10">
            <input type="text" class="form-control" value={this.state.userForm.username} onInput={linkEvent(this, this.handleRegisterUsernameChange)} required minLength={3} maxLength={20} pattern="[a-zA-Z0-9_]+" />
          </div>
        </div>
        <div class="form-group row">
          <label class="col-sm-2 col-form-label">Email</label>
          <div class="col-sm-10">
            <input type="email" class="form-control" placeholder="Optional" value={this.state.userForm.email} onInput={linkEvent(this, this.handleRegisterEmailChange)} minLength={3} />
          </div>
        </div>
        <div class="form-group row">
          <label class="col-sm-2 col-form-label">Password</label>
          <div class="col-sm-10">
            <input type="password" value={this.state.userForm.password} onInput={linkEvent(this, this.handleRegisterPasswordChange)} class="form-control" required />
          </div>
        </div>
        <div class="form-group row">
          <label class="col-sm-2 col-form-label">Verify Password</label>
          <div class="col-sm-10">
            <input type="password" value={this.state.userForm.password_verify} onInput={linkEvent(this, this.handleRegisterPasswordVerifyChange)} class="form-control" required />
          </div>
        </div>
        <div class="form-group row">
          <div class="col-sm-10">
            <button type="submit" class="btn btn-secondary">{this.state.userLoading ? 
            <svg class="icon icon-spinner spin"><use xlinkHref="#icon-spinner"></use></svg> : 'Sign Up'}</button>

          </div>
        </div>
      </form>
    );
  }


  handleRegisterSubmit(i: Setup, event: any) {
    event.preventDefault();
    i.state.userLoading = true;
    i.setState(i.state);
    event.preventDefault();
    WebSocketService.Instance.register(i.state.userForm);
  }

  handleRegisterUsernameChange(i: Setup, event: any) {
    i.state.userForm.username = event.target.value;
    i.setState(i.state);
  }

  handleRegisterEmailChange(i: Setup, event: any) {
    i.state.userForm.email = event.target.value;
    i.setState(i.state);
  }

  handleRegisterPasswordChange(i: Setup, event: any) {
    i.state.userForm.password = event.target.value;
    i.setState(i.state);
  }

  handleRegisterPasswordVerifyChange(i: Setup, event: any) {
    i.state.userForm.password_verify = event.target.value;
    i.setState(i.state);
  }

  parseMessage(msg: any) {
    let op: UserOperation = msgOp(msg);
    if (msg.error) {
      alert(msg.error);
      this.state.userLoading = false;
      this.setState(this.state);
      return;
    } else if (op == UserOperation.Register) {
      this.state.userLoading = false;
      this.state.doneRegisteringUser = true;
      let res: LoginResponse = msg;
      UserService.Instance.login(res);
      console.log(res);
      this.setState(this.state);
    } else if (op == UserOperation.CreateSite) {
      this.props.history.push('/');
    }
  }
}
