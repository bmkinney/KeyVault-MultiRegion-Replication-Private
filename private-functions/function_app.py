import logging

import azure.functions as func

from replication import build_replicator

app = func.FunctionApp()


@app.timer_trigger(
    schedule="%ReplicationPollSchedule%",
    arg_name="timer",
    run_on_startup=False,
    use_monitor=True,
)
def poll_secrets(timer: func.TimerRequest) -> None:
    if timer.past_due:
        logging.warning("Secret replication poll is running late")
    try:
        with build_replicator() as replicator:
            replicator.poll()
    except Exception:
        logging.exception("Private secret replication poll failed")
        raise


@app.service_bus_queue_trigger(
    arg_name="msg",
    queue_name="kv-events",
    connection="ServiceBusConnection",
)
def replicate_secret(msg: func.ServiceBusMessage) -> None:
    try:
        with build_replicator() as replicator:
            replicator.replicate(msg.get_body().decode("utf-8"))
    except Exception:
        logging.exception("Private secret replication message failed")
        raise
