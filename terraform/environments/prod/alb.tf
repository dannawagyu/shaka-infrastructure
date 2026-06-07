locals {
  alb_name               = "${local.name_prefix}-alb"
  alb_target_group_name  = "${local.name_prefix}-app"
  alb_access_logs_bucket = "dannawagyu-shaka-prod-alb-access-logs"
  alb_logs_prefix        = "alb"
}

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "Internet-facing ALB for the Shaka production app host"
  vpc_id      = data.aws_subnet.existing_public.vpc_id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb"
  })
}

resource "aws_security_group_rule" "alb_ingress_http" {
  type              = "ingress"
  description       = "HTTP from the internet for ACME challenge fallback and HTTP-to-HTTPS redirect"
  security_group_id = aws_security_group.alb.id
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
}

resource "aws_security_group_rule" "alb_ingress_https" {
  type              = "ingress"
  description       = "HTTPS from the internet"
  security_group_id = aws_security_group.alb.id
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
}

resource "aws_security_group_rule" "alb_egress_to_app" {
  type                     = "egress"
  description              = "ALB to existing Shaka app EC2 over HTTP"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = var.existing_app_security_group_id
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
}

resource "aws_security_group_rule" "app_ingress_from_alb" {
  type                     = "ingress"
  description              = "HTTP from the Shaka production ALB"
  security_group_id        = var.existing_app_security_group_id
  source_security_group_id = aws_security_group.alb.id
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
}

resource "aws_acm_certificate" "alb" {
  domain_name       = var.alb_domain_name
  validation_method = "DNS"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for record in aws_acm_certificate.alb.domain_validation_options : record.resource_record_name]

  timeouts {
    create = "60m"
  }
}

resource "aws_s3_bucket" "alb_access_logs" {
  bucket = local.alb_access_logs_bucket

  tags = merge(local.common_tags, {
    Name = local.alb_access_logs_bucket
  })
}

resource "aws_s3_bucket_public_access_block" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  versioning_configuration {
    status = "Suspended"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  rule {
    id     = "expire-current-objects"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "alb_access_logs" {
  # ALB access logs to S3 require the ELB-specific log-delivery service principal
  # (logdelivery.elasticloadbalancing.amazonaws.com). delivery.logs.amazonaws.com is
  # the CloudWatch Logs / VPC Flow Logs / NLB principal and is rejected for ALB.
  # The condition scopes to load balancers in this account+region using aws:SourceArn,
  # which is the AWS-documented best practice for ALB access log buckets.
  # See https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html
  statement {
    sid    = "AllowELBLogDelivery"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_access_logs.arn}/${local.alb_logs_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:elasticloadbalancing:${var.aws_region}:${data.aws_caller_identity.current.account_id}:loadbalancer/*"]
    }
  }

  # Belt-and-suspenders: AWS docs for the modern principal only require s3:PutObject
  # (BucketOwnerEnforced makes ACL checks moot), but legacy ELB log delivery flows
  # historically required s3:GetBucketAcl. Granting it is harmless and removes a
  # whole class of "Access Denied" failure modes during ALB log enablement.
  statement {
    sid    = "AllowELBLogDeliveryAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.alb_access_logs.arn]

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:elasticloadbalancing:${var.aws_region}:${data.aws_caller_identity.current.account_id}:loadbalancer/*"]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.alb_access_logs.arn,
      "${aws_s3_bucket.alb_access_logs.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id
  policy = data.aws_iam_policy_document.alb_access_logs.json

  depends_on = [
    aws_s3_bucket_public_access_block.alb_access_logs,
  ]
}

resource "aws_lb" "shaka" {
  name               = local.alb_name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.alb_public_subnet_ids

  enable_deletion_protection = true
  drop_invalid_header_fields = true
  desync_mitigation_mode     = "defensive"

  access_logs {
    bucket  = aws_s3_bucket.alb_access_logs.id
    prefix  = local.alb_logs_prefix
    enabled = true
  }

  tags = merge(local.common_tags, {
    Name = local.alb_name
  })

  depends_on = [
    aws_s3_bucket_policy.alb_access_logs,
  ]
}

resource "aws_lb_target_group" "shaka_app" {
  name        = local.alb_target_group_name
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_subnet.existing_public.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "traffic-port"
    path                = "/actuator/health"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }

  tags = merge(local.common_tags, {
    Name = local.alb_target_group_name
  })
}

resource "aws_lb_target_group_attachment" "shaka_app" {
  target_group_arn = aws_lb_target_group.shaka_app.arn
  target_id        = var.existing_app_instance_id
  port             = 80
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.shaka.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.shaka.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.alb.certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

# Scanner-path blocklist intentionally absent. The HTTPS listener's default action
# is a fixed-response 404, which makes the listener already a default-deny / allowlist
# (only the forward_* rules below let traffic reach the app). Adding explicit scanner
# blocks would not improve security and would create unbounded pattern maintenance.

resource "aws_lb_listener_rule" "forward_auth" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 200

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.shaka_app.arn
  }

  condition {
    path_pattern {
      values = ["/api/v1/auth"]
    }
  }

  condition {
    http_request_method {
      values = ["POST"]
    }
  }
}

resource "aws_lb_listener_rule" "forward_health" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 300

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.shaka_app.arn
  }

  condition {
    path_pattern {
      values = ["/actuator/health"]
    }
  }

  condition {
    http_request_method {
      values = ["GET"]
    }
  }
}

resource "aws_lb_listener_rule" "forward_protected_api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 400

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.shaka_app.arn
  }

  condition {
    path_pattern {
      values = ["/api/v1/*"]
    }
  }

  condition {
    http_header {
      http_header_name = "Authorization"
      values           = ["Bearer *"]
    }
  }
}

# Fallback for /api/v1/* requests that did not match forward_protected_api
# (no Authorization header, malformed Bearer value, etc.). Returns a standard
# 401 so clients can drive their re-auth flow instead of seeing a 404.
# Random non-API paths still hit the listener default (404).
resource "aws_lb_listener_rule" "unauthenticated_api_401" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 401

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Unauthorized"
      status_code  = "401"
    }
  }

  condition {
    path_pattern {
      values = ["/api/v1/*"]
    }
  }
}

# OPTIONS preflight must evaluate before the 401 fallback (priority 401), otherwise
# CORS preflight requests against /api/v1/* — which carry no Authorization header —
# would match unauthenticated_api_401 and break the browser preflight handshake.
resource "aws_lb_listener_rule" "forward_options_preflight" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 350

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.shaka_app.arn
  }

  condition {
    http_request_method {
      values = ["OPTIONS"]
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_host" {
  alarm_name          = "${local.alb_name}-unhealthy-host"
  alarm_description   = "Shaka production ALB has any unhealthy target"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.shaka.arn_suffix
    TargetGroup  = aws_lb_target_group.shaka_app.arn_suffix
  }

  tags = merge(local.common_tags, {
    Name = "${local.alb_name}-unhealthy-host"
  })
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.alb_name}-5xx"
  alarm_description   = "Shaka production ALB returns elevated 5xx responses"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.shaka.arn_suffix
  }

  tags = merge(local.common_tags, {
    Name = "${local.alb_name}-5xx"
  })
}

resource "aws_cloudwatch_metric_alarm" "alb_target_response_time" {
  alarm_name          = "${local.alb_name}-target-response-time"
  alarm_description   = "Shaka production target response time exceeds 1s p95"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p95"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.shaka.arn_suffix
    TargetGroup  = aws_lb_target_group.shaka_app.arn_suffix
  }

  tags = merge(local.common_tags, {
    Name = "${local.alb_name}-target-response-time"
  })
}
