# IRSA role for External Secrets Operator — reads healthpulse/* secrets

module "eso_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "healthpulse-eso-irsa"

  role_policy_arns = {
    secrets = aws_iam_policy.eso_secrets.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

resource "aws_iam_policy" "eso_secrets" {
  name = "healthpulse-eso-secrets"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = "arn:aws:secretsmanager:us-east-1:588738574057:secret:healthpulse/*"
    }]
  })
}

output "eso_role_arn" {
  value = module.eso_irsa.iam_role_arn
}
