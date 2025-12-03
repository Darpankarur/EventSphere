/**
 * Lambda Function: SNS to SES Email Sender
 * 
 * This function is triggered by SNS and sends emails to individual users via SES
 * 
 * Flow:
 * 1. SNS receives message from notification service
 * 2. SNS triggers this Lambda function
 * 3. Lambda extracts email and message from SNS event
 * 4. Lambda sends email via SES to specific user
 */

const { SESClient, SendEmailCommand } = require('@aws-sdk/client-ses');

// AWS_REGION is automatically available in Lambda environment
const sesClient = new SESClient({ region: process.env.AWS_REGION || 'us-east-1' });
const FROM_EMAIL = process.env.FROM_EMAIL || 'noreply@example.com';

exports.handler = async (event) => {
  console.log('Received SNS event:', JSON.stringify(event, null, 2));
  
  try {
    // Process each SNS record
    for (const record of event.Records) {
      if (record.EventSource === 'aws:sns') {
        const snsMessage = record.Sns;
        
        // Extract email from message attributes
        const emailAttribute = snsMessage.MessageAttributes?.email;
        const toEmail = emailAttribute?.Value;
        
        if (!toEmail) {
          console.error('No email found in message attributes');
          continue;
        }
        
        // Extract subject and message
        const subject = snsMessage.Subject || 'Notification from EventSphere';
        const message = snsMessage.Message;
        
        console.log(`Sending email to: ${toEmail}`);
        console.log(`Subject: ${subject}`);
        
        // Send email via SES
        const params = {
          Source: FROM_EMAIL,
          Destination: {
            ToAddresses: [toEmail]
          },
          Message: {
            Subject: {
              Data: subject,
              Charset: 'UTF-8'
            },
            Body: {
              Text: {
                Data: message,
                Charset: 'UTF-8'
              }
            }
          }
        };
        
        const command = new SendEmailCommand(params);
        const response = await sesClient.send(command);
        
        console.log(`Email sent successfully. MessageId: ${response.MessageId}`);
      }
    }
    
    return {
      statusCode: 200,
      body: JSON.stringify({ message: 'Emails processed successfully' })
    };
    
  } catch (error) {
    console.error('Error processing SNS message:', error);
    throw error;
  }
};
