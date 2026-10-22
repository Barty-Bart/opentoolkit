"""A bounded wake-then-command window. No microphone or model dependencies."""


class CommandSession:
    def __init__(self, timeout=8.0):
        self.timeout = timeout
        self.deadline = 0.0
        self.epoch = None

    def arm(self, now, epoch):
        self.deadline = now + self.timeout
        self.epoch = epoch

    def reset(self):
        self.deadline = 0.0
        self.epoch = None

    def active(self, now, epoch):
        return self.epoch == epoch and now < self.deadline

    def expire(self, now, epoch):
        if self.epoch is not None and not self.active(now, epoch):
            self.reset()
            return True
        return False

    def consume(self, now, epoch):
        allowed = self.active(now, epoch)
        self.reset()
        return allowed
