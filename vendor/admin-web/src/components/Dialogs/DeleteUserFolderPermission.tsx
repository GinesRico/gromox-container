// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2020-2026 grommunio GmbH

import React, { useState } from 'react';
import { Dialog, DialogTitle, DialogContent,Button,
  DialogActions, FormControlLabel, Checkbox, CircularProgress, 
} from '@mui/material';
import { useTranslation } from 'react-i18next';


type DeleteUserFolderPermissionProps = {
  deleting: string;
  onClose: () => void;
  onConfirm: (recursive: boolean) => void;
}


const DeleteUserFolderPermissionDialog = (props: DeleteUserFolderPermissionProps) => {
  const [recursive, setRecursive] = useState<boolean>(false);
  const [loading, setLoading] = useState(false);
  const { t } = useTranslation();
  const { deleting, onConfirm, onClose } = props;

  const handleDelete = (e: React.MouseEvent) => {
    e.preventDefault();
    setLoading(true);
    onConfirm(recursive);
    setRecursive(false); // For user safety
    setLoading(false);
  }

  const handleCheckbox = () => setRecursive(!recursive);

  return (
    <Dialog
      onClose={onClose}
      open={!!deleting}
      maxWidth="sm"
      fullWidth
    >
      <DialogTitle>Remove permissions for {deleting}?</DialogTitle>
      <DialogContent style={{ minWidth: 400 }}>
        <FormControlLabel
          control={
            <Checkbox
              checked={recursive}
              onChange={handleCheckbox}
              name="recursive"
              color="primary"
            />
          }
          label={t("Recursive (Remove permission for all subfolders)?")}
        />
      </DialogContent>
      <DialogActions>
        <Button
          onClick={onClose}
          color="secondary"
        >
          {t('Cancel')}
        </Button>
        <Button
          onClick={handleDelete}
          variant="contained"
          color="secondary"
          type="submit"
          autoFocus
        >
          {loading ? <CircularProgress size={24}/> : t('Confirm')}
        </Button>
      </DialogActions>
    </Dialog>
  );
}


export default DeleteUserFolderPermissionDialog;
